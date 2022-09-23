(* The free abelian group over infinitely many generators, plus variables for
   pieces of same *)

module Atomic = struct
  type t =
    | Base of string (* "second", "gram", "kelvin", "apple", etc. *)
    | Constructor of Path.t (* type constructors; we don't allow parameters *)
    | Universal_variable of string option (* rigid variables *)
end

module Variable = struct
  type t = { name : string option ref } (* Probably fine? *)
end

module Map(sig type t end) : sig
  type t
  val

type t = {
  variables : string list
}
