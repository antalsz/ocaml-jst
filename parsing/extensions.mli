(** Syntax for our custom `ocaml-jst` language extensions.  This module provides
    two things:

    1. A first-class AST for all syntax introduced by our language extensions,
       divided up into one extension per module and all available through
       [extension_expr].
    2. A general scheme for lowering these AST nodes into the existing OCaml AST
       ([Parsetree.expression]), so that we can avoid having to modify the
       existing AST (and therefore can avoid updating every ppx to be compatible
       with `ocaml-jst`), as well as a scheme for lifting OCaml AST nodes that
       were generated this way back to our new [extension_expr] AST.

   This file exposes just the clean interface; for details on why we want this,
   as well as the scheme we use, see the comment at the start of
   [extensions.ml]. *)

(** The AST for list comprehensions *)
module Comprehensions : sig
  type iterator =
    | Range of { start     : Parsetree.expression
               ; stop      : Parsetree.expression
               ; direction : Asttypes.direction_flag }
        (** "= START to STOP" (direction = Upto)
            "= START downto STOP" (direction = Downto) *)
    | In of Parsetree.expression
      (** "in EXPR" *)

  (* CR aspectorzabusky: I wonder if the [pattern] should be merged with [iterator], like
     it is in [Typedtree], since we can't even represent non--variable-or-underscore
     patterns for for loops in Lambda. *)
  type clause_binding =
    { pattern    : Parsetree.pattern
    ; iterator   : iterator
    ; attributes : Parsetree.attribute list }
    (** PAT (in/= ...) [@...] *)

  type clause =
    | For of clause_binding list
        (** "for PAT (in/= ...) and PAT (in/= ...) and ..."; must be nonempty *)
    | When of Parsetree.expression
        (** "when EXPR" *)

  type comprehension =
    { body : Parsetree.expression
        (** The body/generator of the comprehension *)
    ; clauses : clause list
        (** The clauses of the comprehension; must be nonempty *) }

  type comprehension_expr =
    | Cexp_list_comprehension  of comprehension
        (** [BODY ...CLAUSES...] *)
    | Cexp_array_comprehension of comprehension
        (** [|BODY ...CLAUSES...|] *)
end

(** The AST for all our `ocaml-jst` language extensions; one constructor per
    extension.  Some extensions are handled separately and thus are not listed
    here. *)
type extension_expr =
  | Eexp_comprehension of Comprehensions.comprehension_expr

(** Given an AST node representing some syntax from a language extension, along
    with the language extension that we're working with and a location, lower our
    custom AST ([extension_expr]) into the existing OCaml AST.  Always succeeds,
    whether or not the extension is enabled. *)
val expr_of_extension_expr :
  loc:Location.t -> Clflags.Extension.t -> extension_expr -> Parsetree.expression

(** Given any AST node, check to see if it's the lowered form of syntax from a
    language extension; if it is, then return it if said language extension is
    enabled or raise an error otherwise.  Also raises an error if this AST node
    looks like a lowered language extension but is from an unknown extension or
    is otherwise malformed. *)
val extension_expr_of_expr :
  Parsetree.expression -> extension_expr option
