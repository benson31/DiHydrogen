////////////////////////////////////////////////////////////////////////////////
// Copyright 2019-2020 Lawrence Livermore National Security, LLC and other
// DiHydrogen Project Developers. See the top-level LICENSE file for details.
//
// SPDX-License-Identifier: Apache-2.0
////////////////////////////////////////////////////////////////////////////////

#include "h2/meta/Core.hpp"
#include "h2/meta/partial_functions/Apply.hpp"
#include "h2/meta/partial_functions/Placeholders.hpp"
#include "h2/meta/typelist/TypeList.hpp"
#include "h2/meta/typelist/LispAccessors.hpp"
#include "h2/meta/typelist/Sort.hpp"

using namespace h2::meta;
using tlist::Empty;

namespace
{
template <int N>
using IntT = ValueAsType<int, N>;

template <bool B>
using BoolT = ValueAsType<bool, B>;

template <int... Ns>
using IntList = TL<IntT<Ns>...>;

template <typename A, typename B>
struct ValueLess : BoolT<(A::value < B::value)>
{};

using ValLess = ValueLess<pfunctions::_1, pfunctions::_2>;

template <typename T, typename List, typename CompareFn>
struct InsertIntoSortedPFT;

template <typename T, typename List, typename CompareFn>
using InsertIntoSortedPF = Force<InsertIntoSortedPFT<T, List, CompareFn>>;

template <typename T, typename CompareFn>
struct InsertIntoSortedPFT<T, tlist::Empty, CompareFn>
{
    using type = TL<T>;
};

template <typename T, typename List, typename CompareFn>
struct InsertIntoSortedPFT
    : IfThenElseT<pfunctions::Apply<CompareFn, TL<T, tlist::Head<List>>>::value,
                  tlist::Cons<T, List>,
                  tlist::Cons<tlist::Head<List>,
                              InsertIntoSortedPF<T,
                                                 tlist::Tail<List>,
                                                 CompareFn>>>
{};

template <typename List, typename CompareFn>
struct InsertionSortT;

template <typename List, typename CompareFn>
using InsertionSort = Force<InsertionSortT<List, CompareFn>>;

template <typename CompareFn>
struct InsertionSortT<tlist::Empty, CompareFn>
{
    using type = tlist::Empty;
};

template <typename List, typename CompareFn>
struct InsertionSortT
    : InsertIntoSortedPFT<tlist::Head<List>,
                          InsertionSort<tlist::Tail<List>, CompareFn>,
                          CompareFn>
{};

template <typename T>
struct TypeCheck;

} // namespace

// Testing Sort
static_assert(
    EqV<InsertionSort<Empty, ValLess>, Empty>(),
    "Sorting the empty list gives the empty list.");

static_assert(
    EqV<InsertionSort<IntList<13>, ValLess>, IntList<13>>(),
    "Sorting a singleton gives the singleton.");

static_assert(
    EqV<InsertionSort<IntList<5, 4, 3, 2, 1>, ValLess>,
        IntList<1, 2, 3, 4, 5>>(),
    "Sorting a decreasing list; worst case.");

static_assert(
    EqV<InsertionSort<IntList<1, 2, 3, 4, 5>, ValLess>,
        IntList<1, 2, 3, 4, 5>>(),
    "Sorting an increasing list; best case.");

static_assert(
    EqV<InsertionSort<IntList<4, 8, 2, 1, 3, 3, 9, 6>, ValLess>,
        IntList<1, 2, 3, 3, 4, 6, 8, 9>>(),
    "Sort a random list.");
