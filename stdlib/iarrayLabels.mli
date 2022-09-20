(* CR aspectorzabusky: This needs a copyright header; should I copy [arrayLabels.mli]? *)

open! Stdlib

(* NOTE:
   If this file is iarrayLabels.mli, run tools/sync_stdlib_docs after editing it
   to generate iarray.mli.

   If this file is iarray.mli, do not edit it directly -- edit
   iarrayLabels.mli instead.
 *)

(** Operations on immutable arrays. *)

type 'a t = 'a iarray
(** An alias for the type of immutable arrays. *)

external length : 'a iarray -> int = "%array_length"
(** Return the length (number of elements) of the given immutable array. *)

external get : 'a iarray -> int -> 'a = "%array_safe_get"
(** [get a n] returns the element number [n] of immutable array [a].
   The first element has number 0.
   The last element has number [length a - 1].
   You can also write [a.#(n)] instead of [get a n].

   @raise Invalid_argument
   if [n] is outside the range 0 to [(length a - 1)]. *)

external make : int -> 'a -> 'a iarray = "caml_make_vect"
(** [make n x] returns a fresh immutable array of length [n],
   initialized with [x].
   All the elements of this new array are initially
   physically equal to [x] (in the sense of the [==] predicate).
   Consequently, if [x] is mutable, it is shared among all elements
   of the array, and modifying [x] through one of the array entries
   will modify all other entries at the same time.

   @raise Invalid_argument if [n < 0] or [n > Sys.max_array_length].
   If the value of [x] is a floating-point number, then the maximum
   size is only [Sys.max_array_length / 2]. *)

external create_float: int -> float iarray = "caml_make_float_vect"
(** [create_float n] returns a fresh immutable float array of length [n],
    with uninitialized data. *)

val init : int -> f:(int -> 'a) -> 'a iarray
(** [init n ~f] returns a fresh immutable array of length [n],
   with element number [i] initialized to the result of [f i].
   In other terms, [init n ~f] tabulates the results of [f]
   applied to the integers [0] to [n-1].

   @raise Invalid_argument if [n < 0] or [n > Sys.max_array_length].
   If the return type of [f] is [float], then the maximum
   size is only [Sys.max_array_length / 2]. *)

val make_matrix :
  dimx:int -> dimy:int -> 'a -> 'a iarray iarray
(** [make_matrix ~dimx ~dimy e] returns a two-dimensional immutable array
   (an immutable array of immutable arrays) with first dimension [dimx] and
   second dimension [dimy]. All the elements of this new matrix
   are initially physically equal to [e].
   The element ([x,y]) of a matrix [m] is accessed
   with the notation [m.#(x).#(y)].

   @raise Invalid_argument if [dimx] or [dimy] is negative or
   greater than {!Sys.max_array_length}.
   If the value of [e] is a floating-point number, then the maximum
   size is only [Sys.max_array_length / 2]. *)

val append : 'a iarray -> 'a iarray -> 'a iarray
(** [append v1 v2] returns a fresh immutable array containing the
   concatenation of the immutable arrays [v1] and [v2].
   @raise Invalid_argument if
   [length v1 + length v2 > Sys.max_array_length]. *)

val concat : 'a iarray list -> 'a iarray
(** Same as {!append}, but concatenates a list of immutable arrays. *)

val sub : 'a iarray -> pos:int -> len:int -> 'a iarray
(** [sub a ~pos ~len] returns a fresh immutable array of length [len],
   containing the elements number [pos] to [pos + len - 1]
   of immutable array [a].

   @raise Invalid_argument if [pos] and [len] do not
   designate a valid subarray of [a]; that is, if
   [pos < 0], or [len < 0], or [pos + len > length a]. *)

(* CR aspectorzabusky: I dropped [copy] because these are immutable.  Is there
   another reason to leave it in? *)

val to_list : 'a iarray -> 'a list
(** [to_list a] returns the list of all the elements of [a]. *)

val of_list : 'a list -> 'a iarray
(** [of_list l] returns a fresh immutable array containing the elements
   of [l].

   @raise Invalid_argument if the length of [l] is greater than
   [Sys.max_array_length]. *)

(** {1 Converting to and from mutable arrays} *)

(* CR aspectorzabusky: When we add locals, we can do
   {[
     val with_array : int -> 'a -> f:local_ (local_ 'a array -> 'b) -> 'a iarray * 'b
     val with_array' : int -> 'a -> f:local_ (local_ 'a array -> unit) -> 'a iarray
   ]} *)

val to_array : 'a iarray -> 'a array
(** [to_array a] returns a mutable copy of the immutable array [a]; that is, a
   fresh (mutable) array containing the same elements as [a] *)

val of_array : 'a array -> 'a iarray
(** [of_array ma] returns an immutable copy of the mutable array [ma]; that is,
   a fresh immutable array containing the same elements as [ma] *)

(** {1 Iterators} *)

val iter : f:('a -> unit) -> 'a iarray -> unit
(** [iter ~f a] applies function [f] in turn to all
   the elements of [a].  It is equivalent to
   [f a.#(0); f a.#(1); ...; f a.#(length a - 1); ()]. *)

val iteri : f:(int -> 'a -> unit) -> 'a iarray -> unit
(** Same as {!iter}, but the
   function is applied to the index of the element as first argument,
   and the element itself as second argument. *)

val map : f:('a -> 'b) -> 'a iarray -> 'b iarray
(** [map ~f a] applies function [f] to all the elements of [a],
   and builds an immutable array with the results returned by [f]:
   [[| f a.#(0); f a.#(1); ...; f a.#(length a - 1) |]]. *)

val mapi : f:(int -> 'a -> 'b) -> 'a iarray -> 'b iarray
(** Same as {!map}, but the
   function is applied to the index of the element as first argument,
   and the element itself as second argument. *)

val fold_left : f:('a -> 'b -> 'a) -> init:'a -> 'b iarray -> 'a
(** [fold_left ~f ~init a] computes
   [f (... (f (f init a.#(0)) a.#(1)) ...) a.#(n-1)],
   where [n] is the length of the immutable array [a]. *)

val fold_right : f:('b -> 'a -> 'a) -> 'b iarray -> init:'a -> 'a
(** [fold_right ~f a ~init] computes
   [f a.#(0) (f a.#(1) ( ... (f a.#(n-1) init) ...))],
   where [n] is the length of the immutable array [a]. *)


(** {1 Iterators on two arrays} *)


val iter2 : f:('a -> 'b -> unit) -> 'a iarray -> 'b iarray -> unit
(** [iter2 ~f a b] applies function [f] to all the elements of [a]
   and [b].
   @raise Invalid_argument if the immutable arrays are not the same size.
   *)

val map2 : f:('a -> 'b -> 'c) -> 'a iarray -> 'b iarray -> 'c iarray
(** [map2 ~f a b] applies function [f] to all the elements of [a]
   and [b], and builds an immutable array with the results returned by [f]:
   [[| f a.#(0) b.#(0); ...; f a.#(length a - 1) b.#(length b - 1)|]].
   @raise Invalid_argument if the immutable arrays are not the same size. *)


(** {1 Array scanning} *)

val for_all : f:('a -> bool) -> 'a iarray -> bool
(** [for_all ~f [|a1; ...; an|]] checks if all elements
   of the immutable array satisfy the predicate [f]. That is, it returns
   [(f a1) && (f a2) && ... && (f an)]. *)

val exists : f:('a -> bool) -> 'a iarray -> bool
(** [exists ~f [|a1; ...; an|]] checks if at least one element of
    the immutable array satisfies the predicate [f]. That is, it returns
    [(f a1) || (f a2) || ... || (f an)]. *)

val for_all2 : f:('a -> 'b -> bool) -> 'a iarray -> 'b iarray -> bool
(** Same as {!for_all}, but for a two-argument predicate.
   @raise Invalid_argument if the two immutable arrays have different
   lengths. *)

val exists2 : f:('a -> 'b -> bool) -> 'a iarray -> 'b iarray -> bool
(** Same as {!exists}, but for a two-argument predicate.
   @raise Invalid_argument if the two immutable arrays have different
   lengths. *)

val mem : 'a -> set:'a iarray -> bool
(** [mem a ~set] is true if and only if [a] is structurally equal
    to an element of [l] (i.e. there is an [x] in [l] such that
    [compare a x = 0]). *)

val memq : 'a -> set:'a iarray -> bool
(** Same as {!mem}, but uses physical equality
   instead of structural equality to compare list elements. *)

(* CR aspectorzabusky: We should add non–in-place sorting *)

(** {1 Iterators} *)

val to_seq : 'a iarray -> 'a Seq.t
(** Iterate on the immutable array, in increasing order. *)

val to_seqi : 'a iarray -> (int * 'a) Seq.t
(** Iterate on the immutable array, in increasing order, yielding indices along
    elements. *)

val of_seq : 'a Seq.t -> 'a iarray
(** Create an immutable array from the generator *)

(**/**)

(** {1 Undocumented functions} *)

(* The following is for system use only. Do not call directly. *)

external unsafe_get : 'a iarray -> int -> 'a = "%array_unsafe_get"