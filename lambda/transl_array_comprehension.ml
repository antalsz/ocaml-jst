open Lambda
open Typedtree
open Asttypes
open Transl_comprehension_utils
open Lambda_utils.Make
open Lambda_utils.Primitive

(** Array comprehensions are compiled by turning into a nested series of loops
    that mutably update an array.  This is simple to say, but slightly tricky to
    do.  One complexity is that we want to apply an optimization to certain
    array comprehensions: if an array comprehension contains exactly one clause,
    and it’s a [for ... and ...] clause, then we can allocate an array of
    exactly the right size up front (instead of having to grow the generated
    array dynamically, as we usually do).  We call this the *fixed-size array
    comprehension optimization*.  We cannot do this with nested [for]s, as the
    sizes of iterators further to the right could depend on the values generated
    by those on the left; indeed, this is why we have [for ... and ...] instead
    of just allowing the user to nest [for]s.

    In general, there are three major sources of complexity to be aware of in
    this translation:

    1. We need to have a resizable array, as most array comprehensions have an
       unknown size (but see point (2)); however, OCaml arrays can't grow or
       shrink, so we have to do this ourselves.

    2. We need to perform the fixed-size array comprehension optimization, as
       described above; this requires handling things specially when the
       comprehension has the form [[|BODY for ITER and ITER ... and ITER|]].
       This ends up getting its tentacles throughout the entire module, as we
       want to share a lot of the code but have to parameterize it over these
       two kinds of output.

    3. We have to handle the float array optimization, so we can't simply
       allocate arrays in a uniform way; if we don't know what's in the array,
       we have to carefully handle things on the first iteration.  These details
       are more local in scope, but particularly fiddly.

    In general, the structure is: we allocate an array and a mutable index
    counter that starts at [0]; each iterator becomes a loop; [when] clauses
    become an [if] expression, same as with lists; and in the body, every time
    we generate an array element, we set it and increment the index counter by
    one.  If we're not in the fixed-size array case, then we also need the array
    to be growable, the first source of extra complexity; we keep track of the
    array size, and if we would ever exceed it, we double the size of the array.
    This means that at the end, we have to use a subarray operation to cut it
    down to the right size.

    In the fixed-size array case, the second source of extra complexity, we have
    to first compute the size of every iterator and multiply them together; in
    both cases, we have to check for overflow, in which case we simply fail.  We
    also check to see if any of the iterators would be empty (have size [0]), in
    which case we can shortcut this whole process and simply return an empty
    array.  Once we do that, though, the loop body is simpler as there's no need
    to double the array size, and we don't need to cut the list down to size at
    the end.  This has ramifications throughout the translation code, as we have
    to add a bunch of extra special-case logic to handle this: we have to store
    enough information to be able to compute iterator sizes if we need to; we
    have to be able to switch between having a resizable and a fixed-size array;
    we don't need to introduce the same number of variable bindings in each
    case; etc.  Various bits of the code make these decisions (for these
    examples: the [Iterator_bindings] module; the [initial_array] and [body]
    functions; and the [Usage] module, all in [transl_array_comprehension.ml]).

    Finally, handling the float array optimization also affects the initial
    array and the element assignment (so this ends up being a locus for all the
    sources of complexity).  If the array has an unknown array kind
    ([Pgenarray]), then we can't allocate it with nonzero size without having
    the first element!  Thus, no matter whether we are in the normal case or the
    fixed-size case, we have to set the initial array to be completely empty.
    Then, on the first iteration through the loop, we can finally create the
    real array, by allocating either the initial values for a resizable array or
    precisely enough values for a fixed-size array and setting all of them to
    the newly-computed first element of the resulting array.  The initial array
    creation is done by the function [initial_array], and the index checking is
    done (among other things) by the function [body].

    To see some examples of what this translation looks like, consider the
    following array comprehension:
    {[
      [x+y for x = 1 to 3 when x <> 2 for y in [10*x; 100*x]]
      (* = [11; 101; 33; 303] *)
    ]}
    This translates to the (Lambda equivalent of) the following:
    {[
      (* Allocate the (resizable) array *)
      let array_size = ref 8 in
      let array      = ref [|0; 0; 0; 0; 0; 0; 0; 0|] in
      (* Next element to be generated *)
      let index = ref 0 in
      (* for x = 1 to 3 *)
      let start = 1 in
      let stop  = 3 in
      for x = start to stop do
        (* when x <> 2 *)
        if x <> 2 then
          (* for y in [|10*x; 100*x|] *)
          let iter_arr = [|10*x; 100*x|] in
          for iter_ix = 0 to Array.length iter_arr - 1 do
            let y = iter_arr.(iter_ix) in
            (* Resize the array if necessary *)
            begin
              if not (!index < !array_size) then
                array_size := 2 * !array_size;
                array      := Array.append !array !array
            end;
            (* The body: x + y *)
            !array.(!index) <- x + y;
            index := !index + 1
          done
      done;
      (* Cut the array back down to size *)
      Array.sub !array 0 !index
    ]}
    On the other hand, consider this array comprehension, which is subject to the
    fixed-size array comprehension optimization:
    {[
      [|x*y for x = 1 to 3 and y = 10 downto 8|]
      (* = [|10; 9; 8; 20; 18; 16; 30; 27; 24|] *)
    ]}
    This translates to the (Lambda equivalent of) the following rather different
    OCaml:
    {[
      (* ... = 1 to 3 *)
      let start_x = 1  in
      let stop_x  = 3  in
      (* ... = 10 downto 8 *)
      let start_y = 10 in
      let stop_y  = 8  in
      (* Check if any iterators are empty *)
      if start_x > stop_x || start_y < stop_y
      then
        (* If so, return the empty array *)
        [||]
      else
        (* Precompute the array size *)
        let array_size =
          (* Compute the size of the range [1 to 3], failing on overflow (the case
             where the range is correctly size 0 is handled by the emptiness check) *)
          let x_size =
            let range_size = (stop_x - start_x) + 1 in
            if range_size > 0
            then range_size
            else raise (Invalid_argument "integer overflow when precomputing \
                                          the size of an array comprehension")
          in
          (* Compute the size of the range [10 downto 8], failing on overflow (the
             case where the range is correctly size 0 is handled by the emptiness
             check) *)
          let y_size =
            let range_size = (start_y - stop_y) + 1 in
            if range_size > 0
            then range_size
            else raise (Invalid_argument "integer overflow when precomputing \
                                          the size of an array comprehension")
          in
          (* Multiplication that checks for overflow ([y_size] can't be [0] because we
             checked that above *)
          let product = x_size * y_size in
          if product / y_size = x_size
          then product
          else raise (Invalid_argument "integer overflow when precomputing \
                                        the size of an array comprehension")
        in
        (* Allocate the (nonresizable) array *)
        let array = Array.make array_size 0 in
        (* Next element to be generated *)
        let index = ref 0 in
        (* for x = 1 to 3 *)
        for x = start_x to stop_x do
          (* for y = 10 downto 8 *)
          for y = start_y downto stop_y do
            (* The body: x*y *)
            array.(!index) <- x*y;
            index := !index + 1
          done
        done;
        array
    ]}
    You can see that the loop body is tighter, but there's more up-front size
    checking work to be done. *)

(** An implementation note: Many of the functions in this file need to translate
    expressions from Typedtree to lambda; to avoid strange dependency ordering,
    we parameterize those functions by [Translcore.transl_exp], and pass it in
    as a labeled argument, along with the necessary [scopes] labeled argument
    that it requires. *)

(** Sometimes the generated code for array comprehensions reuses certain
    expressions more than once, and sometimes it uses them exactly once. We want
    to avoid using let bindings in the case where the expressions are used
    exactly once, so this module lets us check statically whether the let
    bindings have been created.

    The precise context is that the endpoints of integer ranges and the lengths
    of arrays are used once (as [for] loop endpoints) in the case where the
    array size is not fixed and the array has to be grown dynamically; however,
    they are used multiple times if the array size is fixed, as they are used to
    precompute the size of the newly-allocated array.  Because, in the
    fixed-size case, we need both the bare fact that the bindings exist as well
    as to do computation on these bindings, we can't simply maintain a list of
    bindings; thus, this module, allowing us to work with
    [(Usage.once, Let_binding.t) Usage.if_reused] in the dynamic-size case and
    [(Usage.many, Let_binding.t) Usage.if_reused] in the fixed-size case (as
    as similar [Usage.if_reused] types wrapping other binding-representing
    values). *)
module Usage = struct
  (** A two-state (boolean) type-level enum indicating whether a value is used
      exactly [once] or can be used [many] times *)

  type once = private Once [@@warning "-unused-constructor"]
  type many = private Many [@@warning "-unused-constructor"]

  (** The singleton reifying the above type-level enum, indicating whether
      values are to be used exactly [Once] or can be reused [Many] times *)
  type _ t =
    | Once : once t
    | Many : many t

  (** An option-like type for storing extra data that's necessary exactly when a
      value is to be reused [many] times *)
  type (_, 'a) if_reused =
    | Used_once : (once, 'a) if_reused
    | Reusable  : 'a -> (many, 'a) if_reused

  (** Wrap a value as [Reusable] iff we're in the [Many] case *)
  let if_reused (type u) (u : u t) (x : 'a) : (u, 'a) if_reused = match u with
    | Once -> Used_once
    | Many -> Reusable x

  (** Convert an [if_reused] to a [list], forgetting about the [once]/[many]
      distinction; the list is empty in the [Used_once] case and a singleton in
      the [Reusable] case. *)
  let list_of_reused (type u) : (u, 'a) if_reused -> 'a list = function
    | Used_once  -> []
    | Reusable x -> [x]

  (** Creates a new [Let_binding.t] only if necessary: if the value is to be
      used (as per [usage]) [Once], then we don't need to create a binding, so
      we just return it.  However, if the value is to be reused [Many] times,
      then we create a binding with a fresh variable and return the variable (as
      a lambda term).  Thus, in an environment where the returned binding is
      used, the lambda term refers to the same value in either case. *)
  let let_if_reused (type u) ~(usage : u t) let_kind value_kind name value
      : lambda * (u, Let_binding.t) if_reused =
    match usage with
    | Once ->
        value, Used_once
    | Many ->
        let var, binding =
          Let_binding.make_var let_kind value_kind name value
        in
        var, Reusable binding
end

module Precompute_array_size : sig
  (** Generates the lambda expression that throws the exception once we've
      determined that precomputing the array size has overflowed.  The check for
      overflow is done elsewhere; this just throws the exception
      unconditionally. *)
  val raise_overflow_exn : loc:scoped_location -> lambda

  (** [safe_product_pos_vals ~loc xs] generates the lambda expression that
      computes the product of all the lambda terms in [xs] assuming they are all
      strictly positive (nonzero!) integers, failing if any product overflows
      (equivalently, if the whole product would overflow).  This function must
      look at its inputs multiple times, as they are evaluated more than once
      due to the overflow check; the optional argument [variable_name]
      customizes the string used to name these variables. *)
  val safe_product_pos :
    ?variable_name:string -> loc:scoped_location -> lambda list -> lambda
end = struct
  let raise_overflow_exn ~loc =
    (* CR aspectorzabusky: Is this idiomatic?  Should the argument to [string]
       (a string constant) just get [Location.none] instead? *)
    let loc' = Debuginfo.Scoped_location.to_location loc in
    let slot =
      transl_extension_path
        loc
        Env.initial_safe_string
        Predef.path_invalid_argument
    in
    (* CR aspectorzabusky: Should I call [Translprim.event_after] here?
       [Translcore.asssert_failed] does (via a local intermediary). *)
    Lprim(Praise Raise_regular,
          [Lprim(Pmakeblock(0, Immutable, None, alloc_heap),
                 [ slot
                 ; string
                     ~loc:loc'
                     "integer overflow when precomputing the size of an array \
                      comprehension" ],
                 loc)],
          loc)

  (** [safe_mul_pos_vals ~loc x y] generates the lambda expression that computes
      the product [x * y] of two strictly positive (nonzero!) integers and fails
      if this overflowed; the inputs are required to be values, as they are
      evaluated more than once *)
  let safe_mul_pos_vals ~loc x y =
    let open (val Lambda_utils.int_ops ~loc) in
    let product, product_binding =
      Let_binding.make_var (Immutable Alias) Pintval "product" (x * y)
    in
    (* [x * y] is safe, for strictly positive [x] and [y], iff you can undo the
       multiplication: [(x * y)/y = x].  We assume the inputs are values, so we
       don't have to bind them first to avoid extra computation. *)
    Let_binding.let_one product_binding
      (Lifthenelse(product / y = x,
         product,
         raise_overflow_exn ~loc,
         Pintval))

  (** [safe_product_pos_vals ~loc xs] generates the lambda expression that
      computes the product of all the lambda values in [xs] assuming they are
      all strictly positive (nonzero!) integers, failing if any product
      overflows; the inputs are required to be values, as they are evaluated
      more than once *)
  let safe_product_pos_vals ~loc = function
    (* This operation is associative, so the fact that [List.fold_left] brackets
       as [(((one * two) * three) * four)] shouldn't matter *)
    | x :: xs -> List.fold_left (safe_mul_pos_vals ~loc) x xs
    | []      -> int 1
      (* The empty list case can't happen with comprehensions; we could raise an
         error here instead of returning 1 *)

  (* The inputs are *not* required to be values, as we save them in variables *)
  let safe_product_pos ?(variable_name = "x") ~loc factors =
    let map_snd f (x, y) = x, f y in
    let factors, factor_bindings =
      factors
      |> List.map
           (function
             | Lvar _ as var ->
                 var, None
             | x ->
                 Let_binding.make_var (Immutable Strict) Pintval variable_name x
                 |> map_snd Option.some)
      |> List.split
      |> map_snd (List.filter_map Fun.id)
    in
    Let_binding.let_all factor_bindings (safe_product_pos_vals ~loc factors)
end

(** This module contains the type of bindings generated when translating array
    comprehension iterators ([Typedtree.comprehension_iterator]s).  We need more
    struction than a [Let_binding.t list] because of the fixed-size array
    optimization: if we're translating an array comprehension whose size can be
    determined ahead of time, such as
    [[|x,y for x = 1 to 10 and y in some_array|]], then we need to be able to
    precompute the sizes of the iterators, this also means that sometimes we
    need to bind more information so that we can reuse it.  In the example
    above, that means binding [Array.length some_array], as well as remembering
    that the first loop iterates [to] instead of [downto].  We always need to
    bind [some_array], as it's indexed repeatedly, and we always need to bind
    the bounds of a [for]-[to]/[downto] iterator to get side effect ordering
    right, so we can't simply hide this whole type behind [Usage.if_reused]; we
    need to store some bindings all the time, and some bindings only in the
    fixed-size case.  Thus, this module, which allows you to work with a
    structured representation of the translated iterator bindings. *)
module Iterator_bindings = struct
  (** This is the type of bindings generated when translating array
      comprehension iterators ([Typedtree.comprehension_iterator]).  If we are
      in the fixed-size array case, then ['u = many], and we remember all the
      information about the right-hand sides of the iterators; if not, then
      ['u = once], and we only remember those bindings that could have side
      effects, using the other terms directly.  (This means that we remember the
      [start] and [stop] of [to] and [downto] iterators, and the array on the
      right-hand side of an [in] iterator; this last binding is also always
      referenced multiple times.) *)
  type 'u t =
    | Range of { start     : Let_binding.t (* Always bound *)
               ; stop      : Let_binding.t (* Always bound *)
               ; direction : ('u, direction_flag) Usage.if_reused }
    (** The translation of [Typedtree.Texp_comp_range], an integer iterator
        ([... = ... (down)to ...]) *)
    | Array of { iter_arr : Let_binding.t (* Always bound *)
               ; iter_len : ('u, Let_binding.t) Usage.if_reused }
    (** The translation of [Typedtree.Texp_comp_in], an array iterator
        ([... in ...]).  Note that we always remember the array ([iter_arr]), as
        it's indexed repeatedly no matter what. *)

  (** Get the [Let_binding.t]s out of a translated iterator *)
  let let_bindings = function
    | Range { start; stop; direction = _ } ->
        [start; stop]
    | Array { iter_arr; iter_len } ->
        iter_arr :: Usage.list_of_reused iter_len

  (** Get the [Let_binding.t]s out of a list of translated iterators; this is
      the information we need to translate a full [for] comprehension clause
      ([Typedtree.Texp_comp_for]). *)
  let all_let_bindings bindings = List.concat_map let_bindings bindings

  (** Check if a translated iterator is empty in the fixed-size array case; that
      is, check if this iterator will iterate over zero things. *)
  let is_empty ~loc (t : Usage.many t) =
    let open (val Lambda_utils.int_ops ~loc) in
    match t with
    | Range { start; stop; direction = Reusable direction} -> begin
        let start = Lvar start.id in
        let stop  = Lvar stop.id  in
        match direction with
        | Upto   -> start > stop
        | Downto -> start < stop
      end
    | Array { iter_arr = _; iter_len = Reusable iter_len } ->
        Lvar iter_len.id = l0

  (** Check if any of the translated iterators are empty in the fixed-size array
      case; that is, check if any of these iterators will iterate over zero
      things, and thus check if iterating over all of these iterators together
      will actually iterate over zero things.  This is the information we need
      to optimize away iterating over the values at all if the result would have
      zero elements. *)
  let are_any_empty ~loc ts =
    let open (val Lambda_utils.int_ops ~loc) in
    match List.map (is_empty ~loc) ts with
    | is_empty :: are_empty ->
        (* ( || ) is associative, so the fact that [List.fold_left] brackets as
           [(((one || two) || three) || four)] shouldn't matter *)
        List.fold_left ( || ) is_empty are_empty
    | [] ->
        l0 (* false *)
        (* The empty list case can't happen with comprehensions; we could
           raise an error here instead *)

  (** Compute the size of a single nonempty array iterator in the fixed-size
      array case.  This is either the size of a range, which itself is either
      [stop - start + 1] or [start - stop + 1] depending on if the array is
      counting up ([to]) or down ([downto]), clamped to being nonnegative; or it
      is the length of the array being iterated over.  In the range case, we
      also have to check for overflow.  We require that the iterators be
      nonempty, although this is only important for the range case; generate
      Lambda code that checks the result of [are_any_empty] before entering
      [size_nonempty] to ensure this. *)
  let size_nonempty ~loc : Usage.many t -> lambda = function
    | Range { start     = start
            ; stop      = stop
            ; direction = Reusable direction }
      ->
        let open (val Lambda_utils.int_ops ~loc) in
        let start = Lvar start.id in
        let stop  = Lvar stop.id in
        let low, high = match direction with
          | Upto   -> start, stop
          | Downto -> stop,  start
        in
        (* We can assume that the range is nonempty, but computing its size
           still might overflow *)
        let range_size = Ident.create_local "range_size" in
        Llet(Alias, Pintval, range_size, (high - low) + l1,
          (* If the computed size of the range is positive, there was no
             overflow; if it was zero or negative, then there was overflow *)
          Lifthenelse(Lvar range_size > l0,
            Lvar range_size,
            Precompute_array_size.raise_overflow_exn ~loc,
            Pintval))
    | Array { iter_arr = _; iter_len = Reusable iter_len } ->
        Lvar iter_len.id

  (** Compute the total size of an array built out of a list of translated
      iterators in the fixed-size array case, as long as all the iterators are
      nonempty; since this forms a cartesian product, we take the product of the
      sizes (see [size_nonempty]).  This can overflow, in which case we will
      raise an exception.  This is the operation needed to precompute the fixed
      size of a nonempty fixed-size array; check against [are_any_empty] first
      to address the case of fixedly-empty array. *)
  let total_size_nonempty ~loc (iterators : Usage.many t list) =
    Precompute_array_size.safe_product_pos
      ~variable_name:"iterator_size"
      ~loc
      (List.map (size_nonempty ~loc) iterators)
end

(** Machinery for working with resizable arrays for the results of an array
    comprehension: they are created at a fixed, known, small size, and are
    doubled in size when necessary.  These are the arrays that back array
    comprehensions by default, but not in the fixed-size case; in that case, we
    simply construct an array of the appropriate size directly. *)
module Resizable_array = struct
  (** The starting size of a resizable array.  This is guaranteed to be a small
      power of two.  Because we resize the array by doubling, using a power of
      two means that, under the assumption that [Sys.max_array_length] is of the
      form 2^x-1, the array will only grow too large one iteration before it
      would otherwise exceed the limit.  (In practice, the program will fail by
      running out of memory first.) *)
  let starting_size = 8

  (** Create a fresh resizable array: it is mutable and has [starting_size]
      elements.  We have to provide the initial value as well as the array kind,
      thanks to the float array optimization, so sometimes this will be a
      default value and sometimes it will be the first element of the
      comprehension. *)
  let make ~loc array_kind elt =
    Lprim(Pmakearray(array_kind, Mutable, alloc_heap),
          Misc.replicate_list elt starting_size,
          loc)

  (** Create a new array that's twice the size of the old one.  The first half
      of the array contains the same elements, and the latter half's contents
      are unspecified.  Note that this does not update [array] itself. *)
  let double ~loc array = array_append ~loc array array
  (* Implementing array doubling in by appending an array to itself may not be
     the optimal way to do array doubling, but it's good enough for now *)
end

(** Translates an iterator ([Typedtree.comprehension_iterator]), one piece of a
    [for ... and ... and ...] expression, into Lambda.  We translate iterators
    from the "outermost" iterator inwards, so this translation is done in CPS;
    the result of the translation is actually a function that's waiting for the
    body to fill into the translated loop.  The term generated by this function
    will execute the body (which is likely made of further translated iterators
    and suchlike) once for every value being iterated over, with all the
    variables bound over by the iterator available.

    This function returns both a pair of said CPSed Lambda term and the let
    bindings generated by this term (as an [Iterator_bindings.t], which see).
    The [~usage] argument controls whether the endpoints of the iteration have
    to be saved; if it is [Many], then we are dealing with the fixed-size array
    optimization, and we will generate extra bindings. *)
let iterator ~transl_exp ~scopes ~loc ~(usage : 'u Usage.t)
    : comprehension_iterator
        -> (lambda -> lambda) * 'u Iterator_bindings.t = function
  | Texp_comp_range { ident; pattern = _; start; stop; direction } ->
      let bound name value =
        Let_binding.make_var (Immutable Strict) Pintval
          name (transl_exp ~scopes value)
      in
      let start, start_binding = bound "start" start in
      let stop,  stop_binding  = bound "stop"  stop  in
      let mk_iterator body =
        Lfor { for_id     = ident
             ; for_from   = start
             ; for_to     = stop
             ; for_dir    = direction
             ; for_body   = body
             ; for_region = true }
      in
      mk_iterator, Range { start     = start_binding
                         ; stop      = stop_binding
                         ; direction = Usage.if_reused usage direction }
  | Texp_comp_in { pattern; sequence = iter_arr } ->
      let iter_arr_var, iter_arr_binding =
        Let_binding.make_var (Immutable Strict) Pgenval
          "iter_arr" (transl_exp ~scopes iter_arr)
      in
      let iter_arr_kind = Typeopt.array_kind iter_arr in
      let iter_len, iter_len_binding =
        Usage.let_if_reused ~usage (Immutable Alias) Pintval
          "iter_len"
          (Lprim(Parraylength iter_arr_kind, [iter_arr_var], loc))
      in
      let iter_ix = Ident.create_local "iter_ix" in
      let mk_iterator body =
        let open (val Lambda_utils.int_ops ~loc) in
        (* for iter_ix = 0 to Array.length iter_arr - 1 ... *)
        Lfor { for_id     = iter_ix
             ; for_from   = l0
             ; for_to     = iter_len - l1
             ; for_dir    = Upto
             ; for_region = true
             ; for_body   =
                 Matching.for_let
                   ~scopes
                   pattern.pat_loc
                   (Lprim(Parrayrefu iter_arr_kind,
                          [iter_arr_var; Lvar iter_ix],
                          loc))
                   pattern
                   Pintval
                   body
             }
      in
      mk_iterator, Array { iter_arr = iter_arr_binding
                         ; iter_len = iter_len_binding }

(** Translates an array comprehension binding
    ([Typedtree.comprehension_clause_binding]) into Lambda.  At parse time,
    iterators don't include patterns and bindings do; however, in the typedtree
    representation, the patterns have been moved into the iterators (so that
    range iterators can just have an [Ident.t], for translation into for loops),
    so bindings are just like iterators with a possible annotation.  As a
    result, this function is essentially the same as [iterator], which see. *)
let binding
      ~transl_exp
      ~scopes
      ~loc
      ~usage
      { comp_cb_iterator; comp_cb_attributes = _ } =
  (* CR aspectorzabusky: What do we do with attributes here? *)
  iterator ~transl_exp ~loc ~scopes ~usage comp_cb_iterator

(** Translate the contents of a single [for ... and ...] clause (the contents of
    a [Typedtree.Texp_comp_for]) into Lambda, returning both the [lambda ->
    lambda] function awaiting the body of the translated loop, and the ['u
    Iterator_bindings.t list] containing all the bindings generated by the
    individual iterators.  This function is factored out of [clause] because it
    is also used separately in the fixed-size case. *)
let for_and_clause ~transl_exp ~scopes ~loc ~usage =
  Cps_utils.compose_map_acc (binding ~transl_exp ~loc ~scopes ~usage)

(** Translate a single clause, either [for ... and ...] or [when ...]
    ([Typedtree.comprehension_clause]), into Lambda, returning the [lambda ->
    lambda] function awaiting the body of the loop or conditional corresponding
    to this clause.  The argument to that function will be executed once for
    every tuple of elements being iterated over in the [for ... and ...] case,
    or it will be executed iff the condition is true in the [when] case.

    This function is only used if we are not in the fixed-size array case; see
    [clauses] and [for_and_clause] for more details. *)
let clause ~transl_exp ~scopes ~loc = function
  | Texp_comp_for bindings ->
      let make_clause, var_bindings =
        for_and_clause ~transl_exp ~loc ~scopes ~usage:Once bindings
      in
      fun body -> Let_binding.let_all
                    (Iterator_bindings.all_let_bindings var_bindings)
                    (make_clause body)
  | Texp_comp_when cond ->
      fun body -> Lifthenelse(transl_exp ~scopes cond,
                    body,
                    lambda_unit,
                    Pintval (* [unit] is immediate *))

(** The [array_sizing] type describes whether an array comprehension has been
    translated using the fixed-size array optimization ([Fixed_size]), or it has
    not been but instead been translated using the usual dynamically-sized array
    ([Dynamic_size]).

    If an array comprehension is of the form
    {[
      [|BODY for ITER and ITER ... and ITER|]
    ]}
    then we can compute the size of the resulting array before allocating it
    ([Fixed_size]); otherwise, we cannot ([Dynamic_size]), and we have to
    dynamically grow the array as we iterate and shrink it to size at the
    end. *)
type array_sizing =
  | Fixed_size
  | Dynamic_size

(** The [array_size] type provides both the variable holding the array size
    ([array_size]) and a description of how the array size has been/is being
    computed ([array_sizing]; see the [array_sizing] type for more details).  In
    the case where the array has been translated with the fixed-size array
    optimization (when [sizing] is [Fixed_size]), the variable holding the size
    is immutable; in the usual dynamically-sized array case (when [sizing] is
    [Dynamic_size]), the variable holding the size is be mutable so that the
    array size can be queried and grown. *)
type array_size =
  { array_size   : Ident.t
  ; array_sizing : array_sizing
  }
(* CR aspectorzabusky: The names [array_size] (this type), [array_size] (the
   field name), and [array_sizing] are not great, but I can't think of anything
   better. *)

(** The result of translating the clauses portion of an array comprehension
    (everything but the body) *)
type translated_clauses =
  { array_size         : array_size
  (** Whether the array is of a fixed size or must be grown dynamically, and the
      attendant information; see the [array_size] type for more details. *)
  ; outside_context    : lambda -> lambda
  (** The context that must be in force throughout the entire translated
      comprehension, even before the universal let bindings (the definition of
      the initial array, its current index, and the array size
      ([array_size_binding])); this context is "outside" because it must come so
      far outwards that it isn't generated by the translation.  This will
      generally contain let bindings and checks to enforce conditions required
      by things that come later. *)
  ; array_size_binding : Let_binding.t
  (** The binding that defines the array size ([array_size.array_size]); comes
      in between the [outside_context] and the definition of the array. *)
  ; make_comprehension : lambda -> lambda
  (** The translation of the comprehension's iterators, awaiting the translation
      of the comprehension's body.  All that remains to be done after this
      function is called is the creation and disposal of the array that is being
      constructed. *)
  }

(** Translate the clauses of an array comprehension (everything but the body; a
    [Typedtree.comprehension_clause list], which is the [comp_clauses] field of
    [Typedtree.comprehension]).  This function has to handle the fixed-size
    array case: if the list of clauses is a single [for ... and ...] clause,
    then the array will be preallocated at its full size and the comprehension
    will not have to resize the array (although the float array optimization
    interferes with this slightly -- see [initial_array]); this is also why we
    need the [array_kind].  In the normal case, this function simply wires
    together multiple [clause]s, and provides the variable holding the current
    array size as a binding. *)
let clauses ~transl_exp ~scopes ~loc ~array_kind = function
  | [Texp_comp_for bindings] ->
      let make_comprehension, var_bindings =
        for_and_clause ~transl_exp ~loc ~scopes ~usage:Many bindings
      in
      let array_size, array_size_binding =
        Let_binding.make_id (Immutable Alias) Pintval
          "array_size" (Iterator_bindings.total_size_nonempty ~loc var_bindings)
      in
      let outside_context comprehension =
        Let_binding.let_all
          (Iterator_bindings.all_let_bindings var_bindings)
          (Lifthenelse(Iterator_bindings.are_any_empty ~loc var_bindings,
             (* If the array is known to be empty, we short-circuit and return
                the empty array *)
             (* CR aspectorzabusky: It's safe to make the array immutable
                because it's empty, right? *)
             Lprim(
               Pmakearray(Pgenarray, Immutable, Lambda.alloc_heap),
               [],
               loc),
             (* Otherwise, we translate it normally *)
             comprehension,
             (* CR aspectorzabusky: My understanding is that all empty arrays
                are identical, no matter their [array_kind], and that's why I
                can use [Pgenarray] to create the empty array above but still
                use [array_kind] here.  Is that right? *)
             (* (And the result has the [value_kind] of the array) *)
             Parrayval array_kind))
      in
      { array_size         = { array_size; array_sizing = Fixed_size }
      ; outside_context
      ; array_size_binding
      ; make_comprehension
      }
  | clauses ->
      let array_size, array_size_binding =
        Let_binding.make_id
          Mutable Pintval
          "array_size" (int Resizable_array.starting_size)
      in
      let make_comprehension =
        Cps_utils.compose_map (clause ~transl_exp ~loc ~scopes) clauses
      in
      { array_size         = { array_size; array_sizing = Dynamic_size }
      ; outside_context    = Fun.id
      ; array_size_binding
      ; make_comprehension }

(** Create the initial array that will be filled by an array comprehension,
    returning both its identifier and the let binding that binds it.  The logic
    behind how to create the array is complicated, because it lies at the
    intersection of two special cases (controlled by the two non-location
    arguments to this function):

    * The float array optimization means that we may not know the type of
      elements that go into this array, and so need to wait to actually create
      an array until we have seen the first element.  In this case, we have to
      return an empty array that will get overwritten later.

    * The fixed-size optimization means that we may want to preallocate the
      entire array all at once, instead of allocating a resizable array and
      growing it.

    Importantly, the two cases can co-occur, in which case later code needs to
    be aware of what has happened.

    The array that is returned is bound as a [Variable] in both the case where
    we're subject to the float array optimization (i.e., [array_kind] is
    [Pgenarray]) and in the case where nothing special occurs and the array is
    resizable; in the fixed-size array case, the resulting array is bound
    immutably, although it is still internally mutable.  This logic is important
    when translating comprehension bodies; see [body] for details. *)
let initial_array ~loc ~array_kind ~array_size:{array_size; array_sizing} =
  (* As discussed above, there are three cases to consider for how we allocate
     the array.

     1. We are subject to the float array optimization: The array kind is
        [Pgenarray].  In this case, we create an immutable empty array as a
        [Variable], since rather than being updated it will simply be
        overwritten once we have the first element.  This is the only time a
        fixed-size array needs to be a [Variable], since it will be overwritten
        on the first iteration.
     2. The array is of fixed size and known array kind, in which case we use
        [make_(float_)vect] to create the array, and bind it as [StrictOpt]
        since it never needs to be overwritten to be resized or replaced.
     3. The array is of unknown size and known array kind, in which case we
        create a small array of default values using [Pmakearray] and bind it as
        a [Variable] so that it can be overwritten when its size needs to be
        doubled. *)
  let array_let_kind, array_value =
    (* CR aspectorzabusky: I couldn't get type-based disambiguation to work
       without wrapping the whole match in a type annotation, which seemed
       worse. *)
    let open Let_binding.Let_kind in
    match array_sizing, array_kind with
    (* Case 1: Float array optimization difficulties *)
    | (Fixed_size | Dynamic_size), Pgenarray ->
        Mutable,
        Lprim(Pmakearray(Pgenarray, Immutable, Lambda.alloc_heap), [], loc)
    (* Case 2: Fixed size, known array kind *)
    | Fixed_size, (Pintarray | Paddrarray) ->
        Immutable StrictOpt,
        make_vect ~loc ~length:(Lvar array_size) ~init:(int 0)
    | Fixed_size, Pfloatarray ->
        Immutable StrictOpt, make_float_vect ~loc (Lvar array_size)
    (* Case 3: Unknown size, known array kind *)
    | Dynamic_size, (Pintarray | Paddrarray) ->
        Mutable, Resizable_array.make ~loc array_kind (int 0)
    | Dynamic_size, Pfloatarray ->
        Mutable, Resizable_array.make ~loc array_kind (float 0.)
  in
  Let_binding.make_id array_let_kind Pgenval "array" array_value

(** Generate the code for the body of an array comprehension.  This involves
    translating the body expression (a [Typedtree.expression], which is the
    [comp_body] field of [Typedtree.comprehension), but also handles the logic
    of filling in the array that is being produced by the comprehension.  This
    logic varies depending on whether we are subject to the float array
    optimization or not and whether we are in the fixed size array case or not,
    so the correctness depends on getting the correct bindings from
    [initial_array] and [clauses]. *)
let body
      ~loc
      ~array_kind
      ~array_size:{array_size; array_sizing}
      ~array
      ~index
      ~body
  =
  (* The body of an array comprehension has three jobs:
       1. Compute the next element
       2. Assign it (mutably) to the next element of the array
       3. Advance the index of the next element
     However, there are several pieces of complexity:
       (a) If the array size is not fixed, we have to check if the index has
           overflowed; if it has, we have to double the size of the array.  (The
           complex case corresponds to [array_size.array_sizing] being
           [Dynamic_size].)
       (b) If the array kind is not statically known, we initially created an
           empty array; we have to check if we're on the first iteration and use
           the putative first element of the array as the placeholder value for
           every element of the array.  (The complex case corresponds to
           [array_kind] being [Pgenarray].)
       (c) If both (a) and (b) hold, we shouldn't bother checking for an
           overflowed index on the first loop iteration.
     The result is that we build the "set the element" behavior in three steps:
       i.   First, we build the raw "set the element unconditionally" expression
            ([set_element_raw]).
       ii.  Then, if necessary, we precede that with the resizing check;
            otherwise, we leave the raw behavior alone
            ([set_element_in_bounds]).
       iii. Then, if necessary, we check to see if we're on the first iteration
            and create the fresh array instead if so; otherwise, we leave the
            size-safe behavior alone ([set_element_known_kind_in_bounds]).
       iv.  Finally, we take the resulting safe element-setting behavior (which
            could be equal to the result from any of stages i--iii), and follow
            it up by advancing the index of the element to update.
  *)
  let open (val Lambda_utils.int_ops ~loc) in
  let set_element_raw elt =
    (* array.(index) <- elt *)
    Lprim(Parraysetu array_kind, [Lvar array; Lvar index; elt], loc)
      (* CR aspectorzabusky: Is [array_kind] safe here, since it could be
         [Pgenarray]?  Do we have to learn which it should be? *)
  in
  let set_element_in_bounds elt = match array_sizing with
    | Fixed_size ->
        set_element_raw elt
    | Dynamic_size ->
        Lsequence(
          (* Double the size of the array if it's time... *)
          Lifthenelse(Lvar index < Lvar array_size,
            lambda_unit,
            Lsequence(
              Lassign(array_size, i 2 * Lvar array_size),
              Lassign(array,      Resizable_array.double ~loc (Lvar array))),
            Pintval (* [unit] is immediate *)),
          (* ...and then set the element now that the array is big enough *)
          set_element_raw elt)
  in
  let set_element_known_kind_in_bounds = match array_kind with
    | Pgenarray ->
        let is_first_iteration = (Lvar index = l0) in
        let elt = Ident.create_local "elt" in
        let make_array = match array_sizing with
          | Fixed_size ->
              make_vect ~loc ~length:(Lvar array_size) ~init:(Lvar elt)
          | Dynamic_size ->
              Resizable_array.make ~loc Pgenarray (Lvar elt)
        in
        (* CR aspectorzabusky: Is Pgenval safe here? *)
        Llet(Strict, Pgenval, elt, body,
             Lifthenelse(is_first_iteration,
               Lassign(array, make_array),
               set_element_in_bounds (Lvar elt),
               Pintval (* [unit] is immediate *)))
    | Pintarray | Paddrarray | Pfloatarray ->
        set_element_in_bounds body
  in
  Lsequence(
    set_element_known_kind_in_bounds,
    Lassign(index, Lvar index + l1))

let comprehension
      ~transl_exp ~scopes ~loc ~array_kind { comp_body; comp_clauses } =
  let { array_size; outside_context; array_size_binding; make_comprehension } =
    clauses ~transl_exp ~scopes ~loc ~array_kind comp_clauses
  in
  let array, array_binding = initial_array ~loc ~array_kind ~array_size in
  let index, index_var, index_binding =
    Let_binding.make_id_var Mutable Pintval "index" (int 0)
  in
  (* The core of the comprehension: the array, the index, and the iteration that
     fills everything in.  The translation of the clauses will produce a check
     to see if we can avoid doing the hard work of growing the array, which is
     the case when the array is known to be empty after the fixed-size array
     optimization; we also have to check again when we're done.  *)
  let comprehension =
    Let_binding.let_all
      [array_size_binding; array_binding; index_binding]
      (Lsequence(
         (* Create the array *)
         make_comprehension
           (body
              ~loc
              ~array_kind
              ~array_size
              ~array
              ~index
              ~body:(transl_exp ~scopes comp_body)),
         (* If it was dynamically grown, cut it down to size *)
         match array_size.array_sizing with
         | Fixed_size ->
             Lvar array
         | Dynamic_size ->
             array_sub ~loc (Lvar array) ~offset:(int 0) ~length:index_var))
  in
  (* Wrap the core of the comprehension in any outside context necessary; this
     handles the fixed-size array optimization when it applies *)
  outside_context comprehension
