(* TEST
   plugins="odoc_test.ml"
    * ocamldoc
    flags="-I ${ocamlsrcdir}/ocamldoc -I +compiler-libs"
*)

module rec A : sig type t end = B and B : sig type t = A.t end = A;;
