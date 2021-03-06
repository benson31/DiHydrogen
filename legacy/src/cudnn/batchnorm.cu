#include "distconv/cudnn/batchnorm.hpp"
#include "distconv/util/util_mpi.hpp"
#include "distconv/tensor/algorithms_cuda.hpp"

#include <type_traits>

using distconv::tensor::LocaleMPI;
using distconv::tensor::CUDAAllocator;

template <typename DataType>
using Tensor = distconv::tensor::Tensor<DataType, LocaleMPI, CUDAAllocator>;

namespace distconv {
namespace batchnorm {

// To reduce round-off divergence with the default LBANN code, use the
// same thread mapping and reduction method as LBANN
#if 0
template <typename DataType, typename Allocator>
void channel_sums_and_sqsums(
    int num_current_local_samples,
    Tensor4<DataType, Allocator> &input,
    Tensor4<DataType, Allocator> &sums,
    Tensor4<DataType, Allocator> &sqsums,
    cudaStream_t stream) {
  // Clear GPU memory
  DISTCONV_CHECK_CUDA(cudaMemsetAsync(
      sums.get_buffer(), 0,
      sums.get_local_pitched_size() * sizeof(DataType),
      stream));
  DISTCONV_CHECK_CUDA(cudaMemsetAsync(
      sqsums.get_buffer(), 0,
      sqsums.get_local_pitched_size() * sizeof(DataType),
      stream));

  auto reduction_region = input.get_local_shape();
  reduction_region[-1] = num_current_local_samples;
  tensor::TransformReduceSum(input, reduction_region,
                             sums, [] __device__(DataType x) { return x; },
                             sqsums, [] __device__(DataType x) { return x * x; },
                             stream);
}
#else

template <int ND, typename DataType, int BLOCK_SIZE>
__global__ void channel_sums_and_sqsums_kernel(const DataType *input,
                                               DataType *sums, DataType *sqsums,
                                               tensor::Array<ND> shape,
                                               tensor::Array<ND> input_strides) {
  __shared__ DataType shared_sums[BLOCK_SIZE];
  __shared__ DataType shared_sqsums[BLOCK_SIZE];

  const int tid = threadIdx.x;
  const index_t gidx = threadIdx.x + blockIdx.x * blockDim.x;
  const int ch_idx = blockIdx.y;
  const int num_channels = shape[get_channel_dim()];
  const int num_samples = shape[get_sample_dim()];

  DataType sum = DataType(0);
  DataType sqsum = DataType(0);

  const index_t channel_size = shape.get_size() / num_channels / num_samples;

  if (gidx < channel_size) {
    index_t offset = gidx;
    index_t input_offset = 0;
    for (int d = 0; d < ND -2; ++d) {
      int idx = offset % shape[d];
      input_offset += idx * input_strides[d];
      offset /= shape[d];
    }
    input_offset += ch_idx * input_strides[-2];
    for (int s = 0; s < num_samples; ++s) {
      const DataType x = input[input_offset];
      sum += x;
      sqsum += x * x;

      input_offset += input_strides[-1];
    }
  }

  shared_sums[tid] = sum;
  shared_sqsums[tid] = sqsum;

  // Compute channel sum with shared memory reduction
  // TODO: unroll loops
  for(int stride = BLOCK_SIZE / 2; stride > 0; stride /= 2) {
    __syncthreads();
    if(tid < stride) {
      shared_sums[tid] += shared_sums[tid + stride];
      shared_sqsums[tid] += shared_sqsums[tid + stride];
    }
  }

  // Output channel sum to global memory
  if(tid == 0) {
    atomicAdd(&sums[ch_idx], shared_sums[0]);
    atomicAdd(&sqsums[ch_idx], shared_sqsums[0]);
  }
}

template <int ND, typename Tensor>
void channel_sums_and_sqsums(int num_samples, const Tensor &input, Tensor &sums,
                             Tensor &sqsums, cudaStream_t stream,
                             const std::vector<bool> &reduction_dims,
                             bool reduce) {
  using DataType = typename Tensor::data_type;
  // Clear GPU memory
  DISTCONV_CHECK_CUDA(cudaMemsetAsync(
      sums.get_buffer(), 0,
      sums.get_local_pitched_size() * sizeof(DataType),
      stream));
  DISTCONV_CHECK_CUDA(cudaMemsetAsync(
      sqsums.get_buffer(), 0,
      sqsums.get_local_pitched_size() * sizeof(DataType),
      stream));

  const int num_channels = input.get_local_shape()[get_channel_dim()];
  constexpr int block_size = 256;
  dim3 block_dim(block_size);
  index_t channel_size = input.get_local_size() / num_channels / num_samples;
  dim3 grid_dim((channel_size + block_size - 1) / block_size,
                num_channels);
  auto input_strides = input.get_strides();
  auto shape = input.get_local_shape();
  shape[get_sample_dim()] = num_samples;
  // CUDA grid dimension limitation
  assert_always(num_channels < 65535);

  // Do not contribute to the accumulation if the local tensor is not
  // a split root.
  if (input.get_local_size() > 0 && input.is_split_root()) {
    channel_sums_and_sqsums_kernel<ND, DataType, block_size>
        <<<grid_dim, block_dim, 0, stream>>>(
            input.get_const_base_ptr(),
            sums.get_base_ptr(),
            sqsums.get_base_ptr(),
            shape, input_strides);
  }

  if (reduce) {
    // TODO: only global reduction is supported.
    DISTCONV_CHECK_CUDA(cudaStreamSynchronize(stream));
    sums.allreduce_shared_regions();
    sqsums.allreduce_shared_regions();
  }
}
#endif

#define INSTANTIATE_CHANNEL_SUMS_AND_SQSUMS(ND, TYPE)           \
  template void                                                 \
  channel_sums_and_sqsums<ND, Tensor<TYPE>>(                    \
      int num_samples,                                          \
      const Tensor<TYPE> &input,   Tensor<TYPE> &sums,          \
      Tensor<TYPE> &sqsums, cudaStream_t stream,                \
      const std::vector<bool> &reduction_dims,                  \
      bool reduce);
INSTANTIATE_CHANNEL_SUMS_AND_SQSUMS(4, float)
INSTANTIATE_CHANNEL_SUMS_AND_SQSUMS(4, double)
INSTANTIATE_CHANNEL_SUMS_AND_SQSUMS(5, float)
INSTANTIATE_CHANNEL_SUMS_AND_SQSUMS(5, double)
#undef INSTANTIATE_CHANNEL_SUMS_AND_SQSUMS

template <typename DataType>
struct sums_to_statistics_functor {
  index_t m_num_per_sum;
  DataType m_decay;
  sums_to_statistics_functor(index_t num_per_sum, DataType decay):
      m_num_per_sum(num_per_sum),
      m_decay(decay) {}

  __device__ void operator()(DataType &global_mean, DataType &global_var,
                             DataType &running_mean, DataType &running_var) {
    const DataType mean = global_mean / m_num_per_sum;
    const DataType sqmean = global_var / m_num_per_sum;
    DataType var = sqmean- mean * mean;
    var = var > DataType(0) ? var : DataType(0);
    var *= m_num_per_sum / (m_num_per_sum - DataType(1));
    global_mean = mean;
    global_var = var;

    running_mean = m_decay * running_mean + (DataType(1) - m_decay) * mean;
    running_var = m_decay * running_var + (DataType(1) - m_decay) * var;
  }
};

template <int ND, typename TensorType>
void sums_to_statistics(index_t num_per_sum, typename TensorType::data_type decay,
                        TensorType &global_mean, TensorType &global_var,
                        TensorType &running_mean, TensorType &running_var,
                        cudaStream_t stream) {
  using DataType = typename TensorType::data_type;
  if (num_per_sum > 0) {
    tensor::Transform(
        global_mean, global_var, running_mean, running_var,
        sums_to_statistics_functor<DataType>(num_per_sum, decay),
        stream);
  } else {
    // Fill global_var with 1. Do the same thing as the corresponding LBANN code.
    tensor::Transform(
        global_var,
        [] __device__ (DataType &global_var) {
          global_var = DataType(1);
        }, stream);
  }
}

#define INSTANTIATE_SUMS_TO_STATISTICS(ND, TYPE)                \
  template                                                      \
  void sums_to_statistics<ND, Tensor<TYPE>>(                    \
      index_t num_per_sum, TYPE decay,                          \
      Tensor<TYPE> &global_mean, Tensor<TYPE> &global_var,      \
      Tensor<TYPE> &running_mean, Tensor<TYPE> &running_var,    \
      cudaStream_t stream);
INSTANTIATE_SUMS_TO_STATISTICS(4, float)
INSTANTIATE_SUMS_TO_STATISTICS(4, double)
INSTANTIATE_SUMS_TO_STATISTICS(5, float)
INSTANTIATE_SUMS_TO_STATISTICS(5, double)
#undef INSTANTIATE_SUMS_TO_STATISTICS

__device__ inline float rsqrt(float x) {
  return rsqrtf(x);
}

template <int ND, typename DataType>
void __global__ batch_normalization_kernel(const DataType *input,
                                           const DataType *global_mean,
                                           const DataType *global_var,
                                           const DataType *global_scale,
                                           const DataType *global_bias,
                                           DataType *output,
                                           DataType epsilon,
                                           tensor::Array<ND> shape,
                                           tensor::Array<ND> input_strides,
                                           tensor::Array<ND> output_strides) {
  const int ch_idx = blockIdx.y;
  const int num_channels = shape[get_channel_dim()];
  const int num_samples = shape[get_sample_dim()];
  const DataType mean = global_mean[ch_idx];
  const DataType var = global_var[ch_idx];
  const DataType scale = global_scale[ch_idx];
  const DataType bias = global_bias[ch_idx];
  const DataType inv_stdev = rsqrt(var + epsilon);

  const index_t gidx = threadIdx.x + blockIdx.x * blockDim.x;
  const index_t channel_size = shape.get_size() / num_channels / num_samples;

  if (gidx < channel_size) {
    index_t offset = gidx;
    index_t input_offset = 0, output_offset = 0;
    for (int d = 0; d < ND - 2; ++d) {
      int idx = offset % shape[d];
      input_offset += idx * input_strides[d];
      output_offset += idx * output_strides[d];
      offset /= shape[d];
    }
    input_offset += ch_idx * input_strides[-2];
    output_offset += ch_idx * output_strides[-2];
    for (int s = 0; s < num_samples; ++s) {
      const DataType x = input[input_offset];
      DataType xhat = (x - mean) * inv_stdev;
      DataType y = scale * xhat + bias;
      output[output_offset] = y;

      input_offset += input_strides[-1];
      output_offset += output_strides[-1];
    }
  }
}

template <int ND, typename TensorType>
void batch_normalization(int num_samples, const TensorType &input,
                         const TensorType &mean, const TensorType &var,
                         const TensorType &scale, const TensorType &bias,
                         TensorType &output, typename TensorType::data_type epsilon,
                         cudaStream_t stream) {
  // local tensors can be empty
  if (output.get_local_size() == 0) return;
  const int num_channels = input.get_local_shape()[get_channel_dim()];
  constexpr int block_size = 256;
  dim3 block_dim(block_size);
  index_t channel_size = input.get_local_size() / num_channels / num_samples;
  dim3 grid_dim((channel_size + block_size - 1) / block_size,
                num_channels);
  tensor::Array<ND> input_strides = input.get_strides();
  tensor::Array<ND> output_strides = output.get_strides();
  // CUDA grid dimension limitation
  assert_always(num_channels < 65535);
  tensor::Array<ND> shape = input.get_local_shape();
  shape[get_sample_dim()] = num_samples;
  batch_normalization_kernel<<<grid_dim, block_dim, 0, stream>>>(
      input.get_const_base_ptr(),
      mean.get_const_base_ptr(),
      var.get_const_base_ptr(),
      scale.get_const_base_ptr(),
      bias.get_const_base_ptr(),
      output.get_base_ptr(),
      epsilon, shape,
      input_strides, output_strides);
}

#define INSTANTIATE_BATCH_NORMALIZATION(ND, TYPE)               \
  template                                                      \
  void batch_normalization<ND, Tensor<TYPE>>(                   \
      int num_samples,                                          \
      const Tensor<TYPE> &input, const Tensor<TYPE> &mean,      \
      const Tensor<TYPE> &var, const Tensor<TYPE> &scale,       \
      const Tensor<TYPE> &bias, Tensor<TYPE> &output,           \
      TYPE epsilon, cudaStream_t stream);
INSTANTIATE_BATCH_NORMALIZATION(4, float)
INSTANTIATE_BATCH_NORMALIZATION(4, double)
INSTANTIATE_BATCH_NORMALIZATION(5, float)
INSTANTIATE_BATCH_NORMALIZATION(5, double)
#undef INSTANTIATE_BATCH_NORMALIZATION

template <int ND, typename DataType, int BLOCK_SIZE>
void __global__ backprop1_kernel(const DataType *input,
                                 const DataType *d_output,
                                 const DataType *global_mean,
                                 const DataType *global_var,
                                 const DataType *global_scale,
                                 DataType *global_dscale, DataType *global_dbias,
                                 DataType *global_dmean, DataType *global_dvar,
                                 DataType epsilon, tensor::Array<ND> shape,
                                 tensor::Array<ND> input_strides,
                                 tensor::Array<ND> d_output_strides) {
  __shared__ DataType shared_dscale[BLOCK_SIZE];
  __shared__ DataType shared_dbias[BLOCK_SIZE];
  __shared__ DataType shared_dmean[BLOCK_SIZE];
  __shared__ DataType shared_dvar[BLOCK_SIZE];

  const int tid = threadIdx.x;
  const index_t gidx = threadIdx.x + blockIdx.x * blockDim.x;
  const int ch_idx = blockIdx.y;
  const int num_channels = shape[get_channel_dim()];
  const int num_samples = shape[get_sample_dim()];

  const DataType mean = global_mean[ch_idx];
  const DataType var = global_var[ch_idx];
  const DataType scale = global_scale[ch_idx];
  const DataType inv_stdev = rsqrt(var + epsilon);
  const DataType dvar_factor = inv_stdev * inv_stdev * inv_stdev / 2;

  DataType dscale = DataType(0);
  DataType dbias = DataType(0);
  DataType dmean = DataType(0);
  DataType dvar = DataType(0);

  const index_t channel_size = shape.get_size() / num_channels / num_samples;

  if (gidx < channel_size) {
    index_t offset = gidx;
    index_t input_offset = 0, d_output_offset = 0;
    for (int d = 0; d < ND -2; ++d) {
      int idx = offset % shape[d];
      input_offset += idx * input_strides[d];
      d_output_offset += idx * d_output_strides[d];
      offset /= shape[d];
    }
    input_offset += ch_idx * input_strides[-2];
    d_output_offset += ch_idx * d_output_strides[-2];
    for (int sample_idx = 0; sample_idx < num_samples; ++sample_idx) {
      const DataType x = input[input_offset];
      const DataType xhat = (x - mean) * inv_stdev;
      const DataType dy = d_output[d_output_offset];
      dscale += dy * xhat;
      dbias += dy;
      const DataType dxhat = dy * scale;
      dmean += - dxhat * inv_stdev;
      dvar += - dxhat * (x - mean) * dvar_factor;

      input_offset += input_strides[-1];
      d_output_offset += d_output_strides[-1];
    }
  }
  shared_dscale[tid] = dscale;
  shared_dbias[tid] = dbias;
  shared_dmean[tid] = dmean;
  shared_dvar[tid] = dvar;

  for(int stride = BLOCK_SIZE / 2; stride > 0; stride /= 2) {
    __syncthreads();
    if(tid < stride) {
      shared_dscale[tid] += shared_dscale[tid + stride];
      shared_dbias[tid] += shared_dbias[tid + stride];
      shared_dmean[tid] += shared_dmean[tid + stride];
      shared_dvar[tid] += shared_dvar[tid + stride];
    }
  }

  // Output channel sum to global memory
  if (tid == 0) {
    atomicAdd(&global_dscale[ch_idx], shared_dscale[0]);
    atomicAdd(&global_dbias[ch_idx], shared_dbias[0]);
    atomicAdd(&global_dmean[ch_idx], shared_dmean[0]);
    atomicAdd(&global_dvar[ch_idx], shared_dvar[0]);
  }
}

template <int ND, typename TensorType>
void backprop1(int num_samples, const TensorType &input,
               const TensorType &d_output, const TensorType &mean,
               const TensorType &var, const TensorType &scale,
               TensorType &scale_gradient, TensorType &bias_gradient,
               TensorType &mean_gradient, TensorType &var_gradient,
               typename TensorType::data_type epsilon, cudaStream_t stream) {
  using DataType = typename TensorType::data_type;
  DISTCONV_CHECK_CUDA(cudaMemsetAsync(
      scale_gradient.get_buffer(), 0,
      scale_gradient.get_local_pitched_size() * sizeof(DataType),
      stream));
  DISTCONV_CHECK_CUDA(cudaMemsetAsync(
      bias_gradient.get_buffer(), 0,
      bias_gradient.get_local_pitched_size() * sizeof(DataType),
      stream));
  DISTCONV_CHECK_CUDA(cudaMemsetAsync(
      mean_gradient.get_buffer(), 0,
      mean_gradient.get_local_pitched_size() * sizeof(DataType),
      stream));
  DISTCONV_CHECK_CUDA(cudaMemsetAsync(
      var_gradient.get_buffer(), 0,
      var_gradient.get_local_pitched_size() * sizeof(DataType),
      stream));

  if (input.get_local_size() == 0 || !input.is_split_root()) {
    return;
  }

  const auto input_strides = input.get_strides();
  const auto d_output_strides = d_output.get_strides();
  const int num_channels = input.get_local_shape()[get_channel_dim()];
  // CUDA grid dimension limitation
  assert_always(num_channels < 65535);
  constexpr int block_size = 256;
  dim3 block_dim(block_size);
  auto shape = input.get_local_shape();
  shape[get_sample_dim()] = num_samples;
  index_t channel_size = input.get_local_size() / num_channels / num_samples;
  dim3 grid_dim((channel_size + block_size - 1) / block_size,
                num_channels);
  backprop1_kernel<ND, DataType, block_size><<<grid_dim, block_dim, 0, stream>>>(
      input.get_const_base_ptr(),
      d_output.get_const_base_ptr(),
      mean.get_const_base_ptr(),
      var.get_const_base_ptr(),
      scale.get_const_base_ptr(),
      scale_gradient.get_base_ptr(),
      bias_gradient.get_base_ptr(),
      mean_gradient.get_base_ptr(),
      var_gradient.get_base_ptr(),
      epsilon, shape,
      input_strides, d_output_strides);
}

#define INSTANTIATE_BACKPROP1(ND, TYPE)                         \
  template                                                      \
  void backprop1<ND, Tensor<TYPE>>(                             \
      int num_samples,                                          \
      const Tensor<TYPE> &input, const Tensor<TYPE> &d_output,  \
      const Tensor<TYPE> &mean, const Tensor<TYPE> &var,        \
      const Tensor<TYPE> &scale, Tensor<TYPE> &scale_gradient,  \
      Tensor<TYPE> &bias_gradient, Tensor<TYPE> &mean_gradient, \
      Tensor<TYPE> &var_gradient, TYPE epsilon,                 \
      cudaStream_t stream);
INSTANTIATE_BACKPROP1(4, float)
INSTANTIATE_BACKPROP1(4, double)
INSTANTIATE_BACKPROP1(5, float)
INSTANTIATE_BACKPROP1(5, double)
#undef INSTANTIATE_BACKPROP1

template <int ND, typename DataType>
void __global__ backprop2_kernel(const DataType *input,
                                 const DataType *d_output,
                                 const DataType *global_mean,
                                 const DataType *global_var,
                                 const DataType *global_scale,
                                 const DataType *global_dmean,
                                 const DataType *global_dvar,
                                 DataType *d_input, DataType epsilon,
                                 index_t num_per_sum,
                                 tensor::Array<ND> shape,
                                 tensor::Array<ND> input_strides,
                                 tensor::Array<ND> d_output_strides,
                                 tensor::Array<ND> d_input_strides) {
  const index_t gidx = threadIdx.x + blockIdx.x * blockDim.x;
  const int ch_idx = blockIdx.y;
  const int num_channels = shape[get_channel_dim()];
  const int num_samples = shape[-1];

  const DataType mean = global_mean[ch_idx];
  const DataType var = global_var[ch_idx];
  const DataType scale = global_scale[ch_idx];
  const DataType dmean = global_dmean[ch_idx];
  const DataType dvar = global_dvar[ch_idx];

  const DataType inv_stdev = rsqrt(var + epsilon);
  const DataType dmean_term = dmean / num_per_sum;
  const DataType dvar_term = dvar * 2 / (num_per_sum - 1);

  const index_t channel_size = shape.get_size() / num_channels / num_samples;

  if (gidx < channel_size) {
    index_t offset = gidx;
    index_t input_offset = 0, d_output_offset = 0, d_input_offset = 0;
    for (int d = 0; d < ND - 2; ++d) {
      int idx = offset % shape[d];
      input_offset += idx * input_strides[d];
      d_output_offset += idx * d_output_strides[d];
      d_input_offset += idx * d_input_strides[d];
      offset /= shape[d];
    }
    input_offset += ch_idx * input_strides[-2];
    d_output_offset += ch_idx * d_output_strides[-2];
    d_input_offset += ch_idx * d_input_strides[-2];
    for (int s = 0; s < num_samples; ++s) {
      const DataType x = input[input_offset];
      const DataType dy = d_output[d_output_offset];
      const DataType dxhat = dy * scale;
      DataType dx = dxhat * inv_stdev;
      dx += dmean_term;
      dx += dvar_term * (x - mean);
      d_input[d_input_offset] = dx;

      input_offset += input_strides[-1];
      d_output_offset += d_output_strides[-1];
      d_input_offset += d_input_strides[-1];
    }
  }
}

template <int ND, typename TensorType>
void backprop2(index_t num_samples, index_t num_per_sum,
               const TensorType &input, const TensorType &d_output,
               const TensorType &mean, const TensorType &var,
               const TensorType &scale, const TensorType &mean_gradient,
               const TensorType &var_gradient, TensorType &d_input,
               typename TensorType::data_type epsilon, cudaStream_t stream) {
  using DataType = typename TensorType::data_type;
  if (d_input.get_local_size() == 0) return;
  const int num_channels = input.get_local_shape()[get_channel_dim()];
  constexpr int block_size = 256;
  dim3 block_dim(block_size);
  index_t channel_size = input.get_local_size() / num_channels / num_samples;
  dim3 grid_dim((channel_size + block_size - 1) / block_size,
                num_channels);
  auto input_strides = input.get_strides();
  auto d_output_strides = d_output.get_strides();
  auto d_input_strides = d_input.get_strides();
  auto shape = input.get_local_shape();
  shape[get_sample_dim()] = num_samples;
  // CUDA grid dimension limitation
  assert_always(num_channels < 65535);
  backprop2_kernel<ND, DataType><<<grid_dim, block_dim, 0, stream>>>(
      input.get_const_base_ptr(),
      d_output.get_const_base_ptr(),
      mean.get_const_base_ptr(),
      var.get_const_base_ptr(),
      scale.get_const_base_ptr(),
      mean_gradient.get_const_base_ptr(),
      var_gradient.get_const_base_ptr(),
      d_input.get_base_ptr(),
      epsilon, num_per_sum, shape,
      input_strides, d_output_strides, d_input_strides);
}

#define INSTANTIATE_BACKPROP2(ND, TYPE)                                 \
  template                                                              \
  void backprop2<ND, Tensor<TYPE>>(                                     \
      index_t num_samples, index_t num_per_sum,                         \
      const Tensor<TYPE> &input, const Tensor<TYPE> &d_output,          \
      const Tensor<TYPE> &mean, const Tensor<TYPE> &var,                \
      const Tensor<TYPE> &scale, const Tensor<TYPE> &mean_gradient,     \
      const Tensor<TYPE> &var_gradient, Tensor<TYPE> &d_input,          \
      TYPE epsilon, cudaStream_t stream);
INSTANTIATE_BACKPROP2(4, float)
INSTANTIATE_BACKPROP2(4, double)
INSTANTIATE_BACKPROP2(5, float)
INSTANTIATE_BACKPROP2(5, double)
#undef INSTANTIATE_BACKPROP2

} // namespace batchnorm
} // namespace distconv
