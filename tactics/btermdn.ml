(************************************************************************)
(*         *   The Coq Proof Assistant / The Coq Development Team       *)
(*  v      *         Copyright INRIA, CNRS and contributors             *)
(* <O___,, * (see version control and CREDITS file for authors & dates) *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

open Util
open Constr
open EConstr
open Names
open Pattern

(* Discrimination nets with bounded depth.
   See the module dn.ml for further explanations.
   Eduardo (5/8/97). *)

let dnet_depth = ref 8

type term_label =
| GRLabel of GlobRef.t
| ProdLabel
| LambdaLabel
| SortLabel

let compare_term_label t1 t2 = match t1, t2 with
| GRLabel gr1, GRLabel gr2 -> GlobRef.CanOrd.compare gr1 gr2
| _ -> pervasives_compare t1 t2 (** OK *)

type 'res lookup_res = 'res Dn.lookup_res = Label of 'res | Nothing | Everything

let decomp_pat p =
  let rec decrec acc = function
    | PApp (f,args) -> decrec (Array.to_list args @ acc) f
    | PProj (p, c) ->
      let hole = PMeta None in
      let params = List.make (Projection.npars p) hole in
      (PRef (GlobRef.ConstRef (Projection.constant p)), params @ c :: acc)
    | c -> (c,acc)
  in
  decrec [] p

let decomp sigma t =
  let rec decrec acc c = match EConstr.kind sigma c with
    | App (f,l) -> decrec (Array.fold_right (fun a l -> a::l) l acc) f
    | Proj (p, c) ->
      (* Hack: fake evar to generate [Everything] in the functions below *)
      let hole = mkEvar (Evar.unsafe_of_int (-1), []) in
      let params = List.make (Projection.npars p) hole in
      (mkConst (Projection.constant p), params @ c :: acc)
    | Cast (c1,_,_) -> decrec acc c1
    | _ -> (c,acc)
  in
    decrec [] t

let evaluable_constant c env =
  (* This is a hack to work around a broken Print Module implementation, see
     bug #2668. *)
  if Environ.mem_constant c env then Environ.evaluable_constant c env
  else true

let constr_val_discr env sigma ts t =
  let c, l = decomp sigma t in
  let open GlobRef in
    match EConstr.kind sigma c with
    | Const (c,u) ->
      begin match ts with
      | None ->
        if evaluable_constant c env then Everything
        else Label(GRLabel (ConstRef c),l)
      | Some ts ->
        if evaluable_constant c env && TransparentState.is_transparent_constant ts c then Everything
        else Label(GRLabel (ConstRef c),l)
      end
    | Ind (ind_sp,u) -> Label(GRLabel (IndRef ind_sp),l)
    | Construct (cstr_sp,u) -> Label(GRLabel (ConstructRef cstr_sp),l)
    | Var id ->
      begin match ts with
      | None -> Label(GRLabel (VarRef id),l)
      | Some ts ->
        if Environ.evaluable_named id env && TransparentState.is_transparent_variable ts id then Everything
        else Label(GRLabel (VarRef id),l)
      end
    | Prod (n, d, c) ->
      if Option.is_empty ts then Nothing else Label(ProdLabel, [d; c])
    | Lambda (n, d, c) ->
      if Option.is_empty ts then Nothing
      else if List.is_empty l then Label(LambdaLabel, [d; c])
      else Everything
    | Sort _ -> if Option.is_empty ts then Nothing else Label(SortLabel, [])
    | Evar _ -> if Option.is_empty ts then Nothing else Everything
    | Rel _ | Meta _ | Cast _ | LetIn _ | App _ | Case _ | Fix _ | CoFix _
    | Proj _ | Int _ | Float _ | Array _ -> Nothing

let constr_pat_discr env ts t =
  let open GlobRef in
  if Option.is_empty ts && not (Patternops.occur_meta_pattern t) then
    (* Extremely fishy, and breaks very quickly when fiddled with. Why should
       **ground** terms match **everything** when non-discriminated??? *)
    None
  else match decomp_pat t with
  | PRef ((IndRef _) as ref), args
  | PRef ((ConstructRef _ ) as ref), args -> Some (GRLabel ref,args)
  | PRef ((VarRef v) as ref), args ->
    begin match ts with
    | None -> Some(GRLabel ref,args)
    | Some ts ->
      if Environ.evaluable_named v env && (TransparentState.is_transparent_variable ts v) then None
      else Some(GRLabel ref,args)
    end
  | PRef ((ConstRef c) as ref), args ->
    begin match ts with
    | None ->
      if evaluable_constant c env then None
      else Some (GRLabel ref, args)
    | Some ts ->
      if evaluable_constant c env && TransparentState.is_transparent_constant ts c then None
      else Some (GRLabel ref, args)
    end
  | PVar v, args ->
    begin match ts with
    | None -> None
    | Some ts ->
      if TransparentState.is_transparent_variable ts v then None
      else Some(GRLabel (VarRef v),args)
    end
  | PProd (_, d, c), [] ->
    if Option.is_empty ts then None else Some (ProdLabel, [d ; c])
  | PLambda (_, d, c), [] ->
    if Option.is_empty ts then None else Some (LambdaLabel, [d ; c])
  | PSort s, [] ->
    if Option.is_empty ts then None else Some (SortLabel, [])
  | _ -> None

let bounded_constr_pat_discr env st (t,depth) =
  if Int.equal depth 0 then None
  else match constr_pat_discr env st t with
  | None -> None
  | Some (c,l) -> Some(c,List.map (fun c -> (c,depth-1)) l)

let bounded_constr_val_discr env st sigma (t,depth) =
  if Int.equal depth 0 then
    Nothing
  else match constr_val_discr env sigma st t with
  | Label (c,l) -> Label(c,List.map (fun c -> (c,depth-1)) l)
  | Nothing -> Nothing
  | Everything -> Everything

module Make =
  functor (Z : Map.OrderedType) ->
struct

 module Y = struct
    type t = term_label
    let compare = compare_term_label
 end

 module Dn = Dn.Make(Y)(Z)

 type t = Dn.t

  type pattern = Dn.pattern

  let pattern env st pat =
    Dn.pattern (bounded_constr_pat_discr env st) (pat, !dnet_depth)

  let empty = Dn.empty
  let add = Dn.add
  let rmv = Dn.rmv

  let lookup env sigma st dn t =
    Dn.lookup dn (bounded_constr_val_discr env st sigma) (t,!dnet_depth)

end
