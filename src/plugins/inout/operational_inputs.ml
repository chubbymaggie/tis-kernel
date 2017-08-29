(**************************************************************************)
(*                                                                        *)
(*  This file is part of TrustInSoft Kernel.                              *)
(*                                                                        *)
(*  TrustInSoft Kernel is a fork of Frama-C. All the differences are:     *)
(*    Copyright (C) 2016-2017 TrustInSoft                                 *)
(*                                                                        *)
(*  TrustInSoft Kernel is released under GPLv2                            *)
(*                                                                        *)
(**************************************************************************)

(**************************************************************************)
(*                                                                        *)
(*  This file is part of Frama-C.                                         *)
(*                                                                        *)
(*  Copyright (C) 2007-2015                                               *)
(*    CEA (Commissariat à l'énergie atomique et aux énergies              *)
(*         alternatives)                                                  *)
(*                                                                        *)
(*  you can redistribute it and/or modify it under the terms of the GNU   *)
(*  Lesser General Public License as published by the Free Software       *)
(*  Foundation, version 2.1.                                              *)
(*                                                                        *)
(*  It is distributed in the hope that it will be useful,                 *)
(*  but WITHOUT ANY WARRANTY; without even the implied warranty of        *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the         *)
(*  GNU Lesser General Public License for more details.                   *)
(*                                                                        *)
(*  See the GNU Lesser General Public License version 2.1                 *)
(*  for more details (enclosed in the file licenses/LGPLv2.1).            *)
(*                                                                        *)
(**************************************************************************)
open Cil_datatype
open Cil_types
open Locations

(* Computation of over-approximed operational inputs:
   An acurate computation of these inputs needs the computation of
   under-approximed outputs.
*)

type t = Inout_type.t = {
  over_inputs: Locations.Zone.t;
  over_inputs_if_termination: Locations.Zone.t;
  under_outputs_if_termination: Locations.Zone.t;
  over_outputs: Locations.Zone.t;
  over_outputs_if_termination: Locations.Zone.t;
}

let top = {
  over_inputs = Zone.top;
  over_inputs_if_termination = Zone.top;
  under_outputs_if_termination = Zone.bottom;
  over_outputs = Zone.top;
  over_outputs_if_termination = Zone.top;
}

(* [_if_termination] fields of the type above, which are the one propagated by
   the dataflow analysis of this module. It is meaningless to store the other
   ones, as they come from branches that are by construction not propagated
   until the end by the dataflow. *)
type compute_t = {
  over_inputs_d : Zone.t ;
  under_outputs_d : Zone.t;
  over_outputs_d: Zone.t;
}

(* Initial value for the computation *)
let ct_empty = {
  over_inputs_d = Zone.bottom;
  under_outputs_d = Zone.bottom;
  over_outputs_d = Zone.bottom;
}

let ct_bottom = {
  over_inputs_d = Zone.bottom;
  under_outputs_d = Zone.top;
  over_outputs_d = Zone.bottom;
}

let ct_equal ct1 ct2 =
  Zone.equal ct1.over_inputs_d ct2.over_inputs_d &&
  Zone.equal ct1.under_outputs_d ct2.under_outputs_d &&
  Zone.equal ct1.over_outputs_d ct2.over_outputs_d

let ct_join c1 c2 = {
  over_inputs_d = Zone.join c1.over_inputs_d c2.over_inputs_d;
  under_outputs_d = Zone.meet c1.under_outputs_d c2.under_outputs_d;
  over_outputs_d = Zone.join c1.over_outputs_d c2.over_outputs_d;
}

let ct_is_included c1 c2 =
  Zone.is_included c1.over_inputs_d   c2.over_inputs_d &&
  Zone.is_included c2.under_outputs_d c1.under_outputs_d &&
  Zone.is_included c1.over_outputs_d  c2.over_outputs_d

let ct_join_and_is_included smaller larger =
  let join = ct_join smaller larger in
  join, ct_equal join larger

let ct_pretty fmt x =
  Format.fprintf fmt
    "@[Over-approximated operational inputs: %a@]@\n\
     @[Under-approximated operational outputs: %a@]"
    Zone.pretty x.over_inputs_d
    Zone.pretty x.under_outputs_d

let externalize_zone ~with_formals kf =
  Zone.filter_base
    (Callgraph.Uses.accept_base ~with_formals ~with_locals:false kf)

(* This code evaluates an assigns, computing in particular a sound approximation
   of sure outputs. For an assigns [locs_out \from locs_from], the process
   is the following:
   - evaluate locs_out to locations; discard those that are not exact, as
     we cannot guarantee that they are always assigned
   - evaluate locs_from, as a zone (no need for locations)
   - compute the difference between the out and the froms, ie remove the
     zones that are such that [z \from z] holds

   (Note: large parts of this code are inspired/redundant with
   [assigns_to_zone_foobar_state] in Value/register.ml)
*)
let eval_assigns kf state assigns =
  let treat_one_zone acc (out, froms as asgn) = (* treat a single assign *)
    (* Return a list of independent output zones, plus a zone indicating
       that the zone has been overwritten in a sure way *)
    let clean_deps =
      Locations.Zone.filter_base
        (function
          | Base.Var (v, _) | Base.Allocated (v, _) ->
            not (Kernel_function.is_formal v kf)
          | Base.CLogic_Var _ | Base.Null | Base.String _ -> true)
    in
    let outputs_under, outputs_over, deps =
      try
        if Logic_utils.is_result out.it_content
        then (Zone.bottom, Zone.bottom, Zone.bottom)
        else
          let loc_out_under, loc_out_over, deps =
            !Db.Properties.Interp.loc_to_loc_under_over
              ~result:None
              state
              out.it_content
          in
          (enumerate_valid_bits_under ~for_writing:true loc_out_under,
           enumerate_valid_bits ~for_writing:true loc_out_over,
           clean_deps deps)
      with Invalid_argument _ ->
        Inout_parameters.warning ~current:true ~once:true
          "Failed to interpret assigns clause '%a'"
          Printer.pp_term out.it_content;
        (Zone.bottom, Zone.top, Zone.top)
    in
    (* Compute all inputs as a zone *)
    let inputs =
      try
        match froms with
        | FromAny -> Zone.top
        | From l ->
          let aux acc { it_content = from; _ } =
            let _, loc, deps =
              !Db.Properties.Interp.loc_to_loc_under_over
                ~result:None state from
            in
            let acc = Zone.join (clean_deps deps) acc in
            let z = enumerate_valid_bits ~for_writing:false loc in
            Zone.join z acc
          in
          List.fold_left aux deps l
      with Invalid_argument _ ->
        Inout_parameters.warning ~current:true ~once:true
          "Failed to interpret inputs in assigns clause '%a'"
          Printer.pp_from asgn;
        Zone.top
    in
    (* Fuse all outputs. An output is sure if it was certainly
       overwritten (i.e. is in the left part of an assign clause,
       and if it is not amongst its from.) *)
    (* Note: here we remove an overapproximation from an
       underapproximation to get an underapproximation, which is not
       the usual direction. It works here because diff on non-top zones is
       an exact operation. *)
    let sure_out =
      if Zone.equal Zone.top inputs then Zone.bottom
      else Zone.diff outputs_under inputs
    in
    {
      under_outputs_d = Zone.link acc.under_outputs_d sure_out;
      over_inputs_d = Zone.join acc.over_inputs_d inputs;
      over_outputs_d = Zone.join acc.over_outputs_d outputs_over;
    }
  in
  match assigns with
  | WritesAny ->
    Inout_parameters.warning "no assigns clauses@ for function %a.@ \
                              Results@ will be@ imprecise."
      Kernel_function.pretty kf;
    top
  | Writes l  ->
    let init = { ct_bottom with under_outputs_d = Zone.bottom } in
    let r = List.fold_left treat_one_zone init l in {
      over_inputs = r.over_inputs_d;
      over_inputs_if_termination = r.over_inputs_d;
      under_outputs_if_termination = r.under_outputs_d;
      over_outputs = r.over_outputs_d;
      over_outputs_if_termination = r.over_outputs_d;
    }

let compute_using_prototype_state state kf =
  let behaviors = !Db.Value.valid_behaviors kf state in
  let assigns = Ast_info.merge_assigns behaviors in
  eval_assigns kf state assigns

let compute_using_prototype ?stmt kf =
  let state = Cumulative_analysis.specialize_state_on_call ?stmt kf in
  compute_using_prototype_state state kf

(* Results of this module, consolidated by functions. Formals and locals
   are stored *)
module Internals =
  Kernel_function.Make_Table(Inout_type)
    (struct
      let name = "Internal inouts full"
      let dependencies = [ Db.Value.self ]
      let size = 17
    end)
let () = Ast.add_monotonic_state Internals.self

module CallsiteHash = Value_callstack.Callsite.Hashtbl

(* Results of an an entire call, represented by a pair (stmt, kernel_function]).
   This table is filled by the [-inout-callwise] option, or for functions for
   which only the specification is used. *)
module CallwiseResults =
  State_builder.Hashtbl
    (Value_callstack.Callsite.Hashtbl)
    (Inout_type)
    (struct
      let size = 17
      let dependencies = [Internals.self;
                          Inout_parameters.ForceCallwiseInout.self;
                          Inout_parameters.ForceCallwiseWithGraphInout.self]
      let name = "Operational_inputs.CallwiseResults"
    end)


module GComputer(Fenv:Dataflows.FUNCTION_ENV)(X:sig
    val _version: string
    val _kf: kernel_function
    val graph: Nodegraph.t
    val initial_nodes: State_node.Set.t
    val at_call: stmt -> kernel_function -> Inout_type.t (* Results of the
                                                            analysis for the given call. Must not contain locals or formals *)

  end)
= struct

  type t = compute_t State_node.Map.t (* possible states and corresponding inouts*)

  let non_terminating_inputs = ref Zone.bottom
  let non_terminating_outputs = ref Zone.bottom

  let store_non_terminating_inputs inputs =
    non_terminating_inputs := Zone.join !non_terminating_inputs inputs

  let store_non_terminating_outputs outputs =
    non_terminating_outputs := Zone.join !non_terminating_outputs outputs

  (* Store the 'non-termination' information of a function subcall into
     the current call. [under_outputs] are the current call sure outputs. *)
  let store_non_terminating_subcall under_outputs subcall =
    store_non_terminating_inputs (Zone.diff subcall.over_inputs under_outputs);
    store_non_terminating_outputs subcall.over_outputs

  let catenate c1 c2 =
    let inputs = Zone.diff c2.over_inputs_d c1.under_outputs_d in
    store_non_terminating_inputs inputs;
    { over_inputs_d = Zone.join c1.over_inputs_d inputs;
      under_outputs_d = Zone.link c1.under_outputs_d c2.under_outputs_d;
      over_outputs_d = Zone.join  c1.over_outputs_d c2.over_outputs_d; }

  let bottom = State_node.Map.empty

  let pretty fmt x =
    State_node.Map.iter
      (fun s ct ->
         Format.fprintf fmt "@[State node %a :@]@\n@"
           State_node.pretty s;
         ct_pretty fmt ct)
      x

  let join_to_data (node, ct) data =
    if State_node.Map.mem node data
    then State_node.Map.add node (ct_join ct (State_node.Map.find node data)) data
    else State_node.Map.add node ct data

  let join t1 t2 =
    State_node.Map.fold (fun i ct accmap -> join_to_data (i,ct) accmap) t1 t2

  let is_included t1 t2 =
    try
      State_node.Map.iter
        (fun i ct -> assert (ct_is_included ct (State_node.Map.find i t2)))
        t1;
      true
    with |Not_found |Assert_failure _ -> false

  let join_and_is_included t1 t2 =
    State_node.Map.fold (fun i ct (accmap, accb) ->
        if State_node.Map.mem i t2
        then begin
          let (data, b) = ct_join_and_is_included ct (State_node.Map.find i t2) in
          (State_node.Map.add i data accmap, accb && b)
        end
        else (State_node.Map.add i ct accmap, false)
      ) t1 (t2, true)

  let transfer_exp state exp data =
    let inputs = !Db.From.find_deps_no_transitivity_state state exp in
    let new_inputs = Zone.diff inputs data.under_outputs_d in
    store_non_terminating_inputs new_inputs;
    {data with over_inputs_d = Zone.join data.over_inputs_d new_inputs}

  let transfer_instr stmt state (i: instr) (data: compute_t) =
    let add_out lv deps data =
      let deps, new_outs, exact =
        !Db.Value.lval_to_zone_with_deps_state state
          ~deps:(Some deps) ~for_writing:true lv
      in
      store_non_terminating_outputs new_outs;
      let new_inputs = Zone.diff deps data.under_outputs_d in
      store_non_terminating_inputs new_inputs;
      let new_sure_outs =
        if exact then
          (* There is only one modified zone. So, this is an exact output.
             Add it into the under-approximed outputs. *)
          Zone.link data.under_outputs_d new_outs
        else data.under_outputs_d
      in {
        under_outputs_d = new_sure_outs;
        over_inputs_d = Zone.join data.over_inputs_d new_inputs;
        over_outputs_d = Zone.join data.over_outputs_d new_outs }
    in
    match i with
    | Set (lv, exp, _) ->
      let e_inputs =
        !Db.From.find_deps_no_transitivity_state state exp
      in
      add_out lv e_inputs data

    | Call (lvaloption,funcexp,argl,_) ->
      let funcexp_inputs, called =
        match funcexp.enode with
        | Lval (Var _, NoOffset) ->
          Zone.bottom, Value.Value_results.callees stmt
        | _ -> (* Function pointers *)
          !Db.Value.expr_to_kernel_function_state
            ~deps:(Some Zone.bottom)
            state
            funcexp
      in
      let acc_funcexp_arg_inputs =
        (* add the inputs of [argl] to the inputs of the
                  function expression *)
        List.fold_right
          (fun arg inputs ->
             let arg_inputs = !Db.From.find_deps_no_transitivity_state
                 state arg
             in Zone.join inputs arg_inputs)
          argl
          funcexp_inputs
      in
      let data =
        catenate
          data
          { over_inputs_d = acc_funcexp_arg_inputs ;
            under_outputs_d = Zone.bottom;
            over_outputs_d = Zone.bottom; }
      in
      let for_functions =
        Kernel_function.Hptset.fold
          (fun kf acc  ->
             let res = X.at_call stmt kf in
             store_non_terminating_subcall data.over_outputs_d res;
             let for_function = {
               over_inputs_d = res.over_inputs_if_termination;
               under_outputs_d = res.under_outputs_if_termination;
               over_outputs_d = res.over_outputs_if_termination;
             } in
             ct_join for_function acc)
          called
          ct_bottom

      in
      let result = catenate data for_functions in
      let result =
        (* Treatment for the possible assignment of the call result *)
        (match lvaloption with
         | None -> result
         | Some lv -> add_out lv Zone.bottom result)
      in result

    | _ -> data

  let return_data = ref bottom

  class deps_annotation state =
    object(self)
      inherit Visitor.frama_c_inplace
      val mutable result = Zone.bottom
      method accesses = result
      method add_access deps = result <- Zone.join deps result
      method! vterm tlv =
        let deps =
          try
            let deps =
              !Db.From.find_deps_term_no_transitivity_state
                state
                tlv
            in
            (* TODO: what we should we do with other program points? *)
            let z =
              Cil_datatype.Logic_label.Map.find
                (LogicLabel (None,"Here"))
                deps
            in
            let z =
              Locations.Zone.filter_base
                (function Base.CLogic_Var _ -> false | _ -> true)
                z
            in
            z
          with Db.From.Not_lval -> Zone.bottom
        in
        self#add_access deps;
        Cil.SkipChildren
    end
  let visit_annot state annots =
    let v = new deps_annotation state in
    List.iter (fun annot ->
        ignore (Visitor.visitFramacCodeAnnotation (v:>Visitor.frama_c_visitor) annot))
      annots;
    v#accesses

  let transfer_stmt stmt data =
    let add_to_map stmt node ct map =
      if Stmt.Map.mem stmt map
      then Stmt.Map.add stmt (join_to_data (node, ct) (Stmt.Map.find stmt map)) map
      else
        begin
          let newmap = State_node.Map.add node ct (State_node.Map.empty) in
          Stmt.Map.add stmt newmap map
        end
    in
    let process_node state node statedata accmap =
      match Annotations.code_annot stmt with
      | [] when not (Db.Value.is_reachable state) -> accmap
      | annots ->
        let zone = visit_annot state annots in
        let statedata =
          catenate statedata {statedata with over_inputs_d = zone;}
        in
        let propagate_to_succ_states node accmap newdata =
          Nodegraph.fold_succ
            (fun succ_node accmap -> add_to_map (State_node.stmt succ_node) succ_node newdata accmap)
            X.graph node accmap
        in
        match stmt.skind with
        | Instr i ->
          let new_ct = transfer_instr stmt state i statedata in
          propagate_to_succ_states node accmap new_ct
        | If(exp,_,_,_) | Switch (exp,_,_,_) ->
          let new_ct = transfer_exp state exp statedata in
          propagate_to_succ_states node accmap new_ct
        | Return(Some exp,_) ->
          let statedata = transfer_exp state exp statedata in
          return_data := join_to_data (node,statedata) !return_data;
          assert (stmt.succs == []); accmap
        | Return(None, _) ->
          return_data := join_to_data (node, statedata) !return_data;
          assert (stmt.succs == []); accmap
        | Throw _ | TryCatch _ ->
          Inout_parameters.fatal "Exception node in the AST"
        | UnspecifiedSequence _ | Loop _ | Block _
        | Goto _ | Break _ | Continue _
        | TryExcept _ | TryFinally _
          -> propagate_to_succ_states node accmap statedata
    in
    let stmtmap = State_node.Map.fold (State_node.with_state_node process_node)
        data Stmt.Map.empty in
    Stmt.Map.bindings stmtmap

  let init =
    let start = Kernel_function.find_first_stmt Fenv.kf in
    let initial_nodes = X.initial_nodes in
    let init_map = State_node.Set.fold
        (fun v acc ->
           State_node.Map.add v ct_empty acc)
        initial_nodes
        State_node.Map.empty in
    [start, init_map]

  let end_dataflow () =
    let map_if_termination = !return_data in
    (* Forget about states, merge *)
    let ct_if_termination = State_node.Map.fold
        (fun _node ct accres -> ct_join ct accres)
        map_if_termination ct_bottom in {
      over_inputs_if_termination = ct_if_termination.over_inputs_d;
      under_outputs_if_termination = ct_if_termination.under_outputs_d ;
      over_outputs_if_termination = ct_if_termination.over_outputs_d;
      over_inputs =
        Zone.join !non_terminating_inputs ct_if_termination.over_inputs_d;
      over_outputs =
        Zone.join !non_terminating_outputs ct_if_termination.over_outputs_d;
    }

end


module Computer(Fenv:Dataflows.FUNCTION_ENV)(X:sig
    val _version: string (* Debug: Callwise or functionwise *)
    val _kf: kernel_function (* Debug: Function being analyzed *)
    val stmt_state: stmt -> Db.Value.state (* Memory state at the given stmt *)
    val at_call: stmt -> kernel_function -> Inout_type.t (* Results of the
                                                            analysis for the given call. Must not contain locals or formals *)
  end) = struct

  (* We want to compute the in/out for all terminating and
     non-terminating points of the function. This is not immediate
     with a dataflow, as all (1) infinite loops, (2) branches that call a non
     terminating function, or (3) branches that fail, will not appear in the
     final state. Hence, we two use auxiliary variables into which we add
     all partial results. *)
  let non_terminating_inputs = ref Zone.bottom
  let non_terminating_outputs = ref Zone.bottom

  let store_non_terminating_inputs inputs =
    non_terminating_inputs := Zone.join !non_terminating_inputs inputs

  let store_non_terminating_outputs outputs =
    non_terminating_outputs := Zone.join !non_terminating_outputs outputs

  (* Store the 'non-termination' information of a function subcall into
     the current call. [under_outputs] are the current call sure outputs. *)
  let store_non_terminating_subcall under_outputs subcall =
    store_non_terminating_inputs (Zone.diff subcall.over_inputs under_outputs);
    store_non_terminating_outputs subcall.over_outputs

  let catenate c1 c2 =
    let inputs = Zone.diff c2.over_inputs_d c1.under_outputs_d in
    store_non_terminating_inputs inputs;
    { over_inputs_d = Zone.join c1.over_inputs_d inputs;
      under_outputs_d = Zone.link c1.under_outputs_d c2.under_outputs_d;
      over_outputs_d = Zone.join  c1.over_outputs_d c2.over_outputs_d;
    }

  type t = compute_t

  let pretty = ct_pretty

  let bottom = ct_bottom
  let join_and_is_included = ct_join_and_is_included
  let join = ct_join
  let is_included = ct_is_included

  (* Transfer function on expression. *)
  let transfer_exp s exp data =
    let state = X.stmt_state s in
    let inputs = !Db.From.find_deps_no_transitivity_state state exp in
    let new_inputs = Zone.diff inputs data.under_outputs_d in
    store_non_terminating_inputs new_inputs;
    {data with over_inputs_d = Zone.join data.over_inputs_d new_inputs}

  (* Transfer function on instructions. *)
  let transfer_instr stmt (i: instr) (data: t) =
    let state = X.stmt_state stmt in
    let add_out lv deps data =
      let deps, new_outs, exact =
        !Db.Value.lval_to_zone_with_deps_state state
          ~deps:(Some deps) ~for_writing:true lv
      in
      store_non_terminating_outputs new_outs;
      let new_inputs = Zone.diff deps data.under_outputs_d in
      store_non_terminating_inputs new_inputs;
      let new_sure_outs =
        if exact then
          (* There is only one modified zone. So, this is an exact output.
             Add it into the under-approximed outputs. *)
          Zone.link data.under_outputs_d new_outs
        else data.under_outputs_d
      in {
        under_outputs_d = new_sure_outs;
        over_inputs_d = Zone.join data.over_inputs_d new_inputs;
        over_outputs_d = Zone.join data.over_outputs_d new_outs }
    in
    match i with
    | Set (lv, exp, _) ->
      let state = X.stmt_state stmt in
      let e_inputs =
        !Db.From.find_deps_no_transitivity_state state exp
      in
      add_out lv e_inputs data

    | Call (lvaloption,funcexp,argl,_) ->
      let state = X.stmt_state stmt in
      let funcexp_inputs, called =
        match funcexp.enode with
        | Lval (Var _, NoOffset) ->
          Zone.bottom, Value.Value_results.callees stmt
        | _ -> (* Function pointers *)
          !Db.Value.expr_to_kernel_function_state
            ~deps:(Some Zone.bottom)
            state
            funcexp
      in
      let acc_funcexp_arg_inputs =
        (* add the inputs of [argl] to the inputs of the
           function expression *)
        List.fold_right
          (fun arg inputs ->
             let arg_inputs = !Db.From.find_deps_no_transitivity_state
                 state arg
             in Zone.join inputs arg_inputs)
          argl
          funcexp_inputs
      in
      let data =
        catenate
          data
          { over_inputs_d = acc_funcexp_arg_inputs ;
            under_outputs_d = Zone.bottom;
            over_outputs_d = Zone.bottom; }
      in
      let for_functions =
        Kernel_function.Hptset.fold
          (fun kf acc  ->
             let res = X.at_call stmt kf in
             store_non_terminating_subcall data.over_outputs_d res;
             let for_function = {
               over_inputs_d = res.over_inputs_if_termination;
               under_outputs_d = res.under_outputs_if_termination;
               over_outputs_d = res.over_outputs_if_termination;
             } in
             join for_function acc)
          called
          bottom
      in
      let result = catenate data for_functions in
      let result =
        (* Treatment for the possible assignment of the call result *)
        (match lvaloption with
         | None -> result
         | Some lv -> add_out lv Zone.bottom result)
      in result

    | _ -> data

  (* transfer_guard: gets the state obtained after evaluating the
     condition, and split the state according to the truth value of
     the condition. In this case, we just make sure that dead
     edges get bottom, instead of the input state. *)
  let transfer_guard stmt e t =
    let state = X.stmt_state stmt in
    let v_e = !Db.Value.eval_expr ~with_alarms:CilE.warn_none_mode state e in
    let t1 = Cil.unrollType (Cil.typeOf e) in
    let do_then, do_else =
      if Cil.isIntegralType t1 || Cil.isPointerType t1
      then Cvalue.V.contains_non_zero v_e,
           Cvalue.V.contains_zero v_e
      else true, true (* TODO: a float condition is true iff != 0.0 *)
    in
    (if do_then then t else bottom),
    (if do_else then t else bottom)

  let return_data = ref bottom


  class deps_annotation state =
    object(self)
      inherit Visitor.frama_c_inplace
      val mutable result = Zone.bottom
      method accesses = result
      method add_access deps = result <- Zone.join deps result
      method! vterm tlv =
        let deps =
          try
            let deps =
              !Db.From.find_deps_term_no_transitivity_state
                state
                tlv
            in
            (* TODO: what we should we do with other program points? *)
            let z =
              Cil_datatype.Logic_label.Map.find
                (LogicLabel (None,"Here"))
                deps
            in
            let z =
              Locations.Zone.filter_base
                (function Base.CLogic_Var _ -> false | _ -> true)
                z
            in
            z
          with Db.From.Not_lval -> Zone.bottom
        in
        self#add_access deps;
        Cil.SkipChildren
    end

  let visit_annot state annots =
    let v = new deps_annotation state in
    List.iter (fun annot ->
        ignore (Visitor.visitFramacCodeAnnotation
                  (v:>Visitor.frama_c_visitor)
                  annot))
      annots;
    v#accesses

  let transfer_stmt s data =
    let state = X.stmt_state s in
    match Annotations.code_annot s with
    | [] when not (Db.Value.is_reachable state) -> []
    | annots ->
      (* Always visit the statement, even if the statement is dead because of
         annotations. *)
      let zone = visit_annot state annots in
      let data =
        catenate
          data
          {data with over_inputs_d = zone;}
      in
      let map_on_all_succs new_data =
        List.map (fun x -> (x,new_data)) s.succs
      in
      match s.skind with
      | Instr i -> map_on_all_succs (transfer_instr s i data)
      | If(exp,_,_,_) ->
        let data = transfer_exp s exp data in
        Dataflows.transfer_if_from_guard transfer_guard s data
      | Switch(exp,_,_,_) ->
        let data = transfer_exp s exp data in
        Dataflows.transfer_switch_from_guard transfer_guard s data
      | Return(Some exp,_) -> return_data := transfer_exp s exp data;
        assert (s.succs == []); []
      | Return(None,_) -> return_data := data;
        assert (s.succs == []); []
      | Throw _ | TryCatch _ ->
        Inout_parameters.fatal "Exception node in the AST"
      | UnspecifiedSequence _ | Loop _ | Block _
      | Goto _ | Break _ | Continue _
      | TryExcept _ | TryFinally _ ->
        map_on_all_succs data

  let init = [(Kernel_function.find_first_stmt Fenv.kf), ct_empty]

  let end_dataflow () =
    let res_if_termination = !return_data in {
      over_inputs_if_termination = res_if_termination.over_inputs_d;
      under_outputs_if_termination = res_if_termination.under_outputs_d ;
      over_outputs_if_termination = res_if_termination.over_outputs_d;
      over_inputs =
        Zone.join !non_terminating_inputs res_if_termination.over_inputs_d;
      over_outputs =
        Zone.join !non_terminating_outputs res_if_termination.over_outputs_d;
    }

end


let externalize ~with_formals kf v =
  let filter = externalize_zone ~with_formals kf in
  Inout_type.map filter v

let compute_externals_using_prototype ?stmt kf =
  let internals = compute_using_prototype ?stmt kf in
  externalize ~with_formals:false kf internals

let get_internal_aux ?stmt kf =
  match stmt with
  | None -> !Db.Operational_inputs.get_internal kf
  | Some stmt ->
    try CallwiseResults.find (kf, Kstmt stmt)
    with Not_found ->
      if !Db.Value.use_spec_instead_of_definition kf then
        compute_using_prototype ~stmt kf
      else !Db.Operational_inputs.get_internal kf

let get_external_aux ?stmt kf =
  match stmt with
  | None -> !Db.Operational_inputs.get_external kf
  | Some stmt ->
    try
      let internals = CallwiseResults.find (kf, Kstmt stmt) in
      externalize ~with_formals:false kf internals
    with Not_found ->
      if !Db.Value.use_spec_instead_of_definition kf then
        let r = compute_externals_using_prototype ~stmt kf in
        CallwiseResults.add (kf, Kstmt stmt) r;
        r
      else !Db.Operational_inputs.get_external kf

let extract_inout_from_froms froms =
  let open Function_Froms in
  match froms with
  | Value_types.Froms {deps_return; deps_table } ->
    let in_return = Deps.to_zone deps_return in
    let in_, out_ =
      match deps_table with
      | Memory.Top -> Zone.top, Zone.top
      | Memory.Bottom -> Zone.bottom, Zone.bottom
      | Memory.Map m ->
        let aux_from out in_ (acc_in,acc_out as acc) =
          let open DepsOrUnassigned in
          (* Skip zones fully unassigned, they are not really part of the
             dependencies, but just present in the offsetmap to avoid "holes" *)
          match in_ with
          | DepsBottom | Unassigned -> acc
          | AssignedFrom in_ | MaybeAssignedFrom in_ ->
            Zone.join acc_in (Deps.to_zone in_),
            Zone.join acc_out out
        in
        Memory.fold aux_from m (Zone.bottom, Zone.bottom)
    in
    (Zone.join in_return in_), out_
  | Value_types.Closure _ -> Zone.top, Zone.top


module Callwise = struct

  let compute_callwise () =
    Inout_parameters.ForceCallwiseInout.get () ||
    Dynamic.Parameter.Bool.get "-memexec-all" ()

  let merge_call_in_local_table call local_table v =
    let prev =
      try CallsiteHash.find local_table call
      with Not_found -> Inout_type.bottom
    in
    let joined = Inout_type.join v prev in
    CallsiteHash.replace local_table call joined

  let merge_call_in_global_tables (kf, _ as call) v =
    (* Global callwise table *)
    let prev =
      try CallwiseResults.find call
      with Not_found -> Inout_type.bottom
    in
    CallwiseResults.replace call (Inout_type.join v prev);
    (* Global, kf-indexed, table *)
    let prev =
      try Internals.find kf
      with Not_found -> Inout_type.bottom
    in
    Internals.replace kf (Inout_type.join v prev)

  let merge_local_table_in_global_ones =
    CallsiteHash.iter merge_call_in_global_tables


  let call_inout_stack = ref []

  let call_for_callwise_inout (call_type, state, call_stack,_) =
    if compute_callwise () then begin
      let (current_function, ki as call_site) = List.hd call_stack in
      let merge_inout inout =
        if ki = Kglobal
        then merge_call_in_global_tables call_site inout
        else
          try
            let _above_function, table =
              try List.hd !call_inout_stack
              with Failure _ -> assert false
            in
            merge_call_in_local_table call_site table inout;
          with Failure msg as e ->
            if msg = "hd" then
              Inout_parameters.fatal "inout: empty stack"
                Kernel_function.pretty current_function
            else raise e
      in
      match call_type with
      | `Builtin
          { Value_types.c_from = Some froms; Value_types.c_sureouts = oz; _ } ->
        let in_, out_ = extract_inout_from_froms froms in
        let sure_out =
          match oz with
          | Some sure_out -> sure_out
          | None -> Zone.bottom
        in
        let inout =
          { over_inputs_if_termination = in_;
            over_inputs = in_;
            over_outputs_if_termination = out_ ;
            over_outputs = out_;
            under_outputs_if_termination = sure_out; }
        in
        merge_inout inout
      | `Def | `Memexec ->
        let table_current_function = CallsiteHash.create 7 in
        call_inout_stack :=
          (current_function, table_current_function) :: !call_inout_stack
      | `Spec | `Builtin { Value_types.c_from = None; _ } ->
        let inout = compute_using_prototype_state state current_function in
        merge_inout inout
    end


  module MemExec =
    State_builder.Hashtbl
      (Datatype.Int.Hashtbl)
      (Inout_type)
      (struct
        let size = 17
        let dependencies = [Internals.self]
        let name = "Operational_inputs.MemExec"
      end)

  let end_record call_stack inout =
    merge_local_table_in_global_ones (snd (List.hd !call_inout_stack));
    let (current_function, _ as call_site) = List.hd call_stack in
    (* pop + record in top of stack the inout of function that just finished*)
    match !call_inout_stack with
    | (current_function2, _) :: (((_caller, table) :: _) as tail) ->
      if current_function2 != current_function then
        Inout_parameters.fatal "callwise inout %a != %a@."
          Kernel_function.pretty current_function (* g *)
          Kernel_function.pretty current_function2 (* f *);
      call_inout_stack := tail;
      merge_call_in_local_table call_site table inout;
    | _ ->  (* the entry point, probably *)
      merge_call_in_global_tables call_site inout;
      call_inout_stack := [];
      CallwiseResults.mark_as_computed ()

  let compute_call_from_value_states kf states =
    let module Fenv = (val Dataflows.function_env kf: Dataflows.FUNCTION_ENV) in
    let module Computer = Computer(Fenv)(
      struct
        let _version = "callwise"
        let _kf = kf

        let stmt_state stmt =
          try Cil_datatype.Stmt.Hashtbl.find states stmt
          with Not_found -> Cvalue.Model.bottom

        let at_call stmt kf =
          let _cur_kf, table = List.hd !call_inout_stack in
          try
            let with_internals = CallsiteHash.find table (kf, Kstmt stmt) in
            match kf.fundec with
            | Definition (fundec, _) ->
              let filter = Zone.filter_base
                  (fun b -> not (Base.is_formal_or_local b fundec))
              in
              Inout_type.map filter with_internals
            | _ -> with_internals
          with Not_found -> Inout_type.bottom
      end) in
    let module Compute = Dataflows.Simple_forward(Fenv)(Computer) in
    Computer.end_dataflow ()

  let record_for_callwise_inout ((call_stack: Db.Value.callstack), value_res) =
    if compute_callwise () then
      let inout = match value_res with
        | Value_types.Normal (states, _after_states)
        | Value_types.NormalStore ((states, _after_states), _) ->
          let kf = fst (List.hd call_stack) in
          let inout =
            if !Db.Value.no_results kf then
              top
            else
              compute_call_from_value_states kf (Lazy.force states)
          in
          Db.Operational_inputs.Record_Inout_Callbacks.apply
            (call_stack, inout);
          (match value_res with
           | Value_types.NormalStore (_, memexec_counter) ->
             MemExec.replace memexec_counter inout
           | _ -> ());
          inout

        | Value_types.Reuse counter ->
          MemExec.find counter
      in
      end_record call_stack inout


  (* Register our callbacks inside the value analysis *)

  let add_hooks () =
    Db.Value.Record_Value_Callbacks_New.extend_once record_for_callwise_inout;
    Db.Value.Call_Type_Value_Callbacks.extend_once call_for_callwise_inout

  let () = Inout_parameters.ForceCallwiseInout.add_update_hook
      (fun _bold bnew -> if bnew then add_hooks ())

  let () = Inout_parameters.ForceCallwiseInout.add_set_hook
      (fun bold bnew ->
         if bold = false && bnew then
           Project.clear
             ~selection:(State_selection.with_dependencies Db.Value.self) ();
      )

end


module CallWiseWithGraph = struct

  let compute_callwise_graph () =
    Inout_parameters.ForceCallwiseWithGraphInout.get () ||
    Dynamic.Parameter.Bool.get "-memexec-all" ()

  let merge_call_in_local_table call local_table v =
    let prev =
      try CallsiteHash.find local_table call
      with Not_found -> Inout_type.bottom
    in
    let joined = Inout_type.join v prev in
    CallsiteHash.replace local_table call joined

  let merge_call_in_global_tables (kf, _ as call) v =
    (* Global callwise table *)
    let prev =
      try CallwiseResults.find call
      with Not_found -> Inout_type.bottom
    in
    CallwiseResults.replace call (Inout_type.join v prev);
    (* Global, kf-indexed, table *)
    let prev =
      try Internals.find kf
      with Not_found -> Inout_type.bottom
    in
    Internals.replace kf (Inout_type.join v prev)

  let merge_local_table_in_global_ones =
    CallsiteHash.iter merge_call_in_global_tables

  let call_inout_stack = ref []

  let call_for_callwise_inout (call_type, state, call_stack,_) =
    if compute_callwise_graph () then begin
      let (current_function, ki as call_site) = List.hd call_stack in
      let merge_inout inout =
        if ki = Kglobal
        then merge_call_in_global_tables call_site inout
        else
          try
            let _above_function, table =
              try List.hd !call_inout_stack
              with Failure _ -> assert false
            in
            merge_call_in_local_table call_site table inout;
          with Failure msg as e ->
            if msg = "hd" then
              Inout_parameters.fatal "inout: empty stack"
                Kernel_function.pretty current_function
            else raise e
      in
      match call_type with
      | `Builtin
          { Value_types.c_from = Some froms; Value_types.c_sureouts = oz; _ } ->
        let in_, out_ = extract_inout_from_froms froms in
        let sure_out = match oz with
          | Some sure_out -> sure_out
          | None -> Zone.bottom
        in
        let inout = {
          over_inputs_if_termination = in_;
          over_inputs = in_;
          over_outputs_if_termination = out_ ;
          over_outputs = out_;
          under_outputs_if_termination = sure_out;
        } in
        merge_inout inout
      | `Def  ->
        let table_current_function = CallsiteHash.create 7 in
        call_inout_stack :=
          (current_function, table_current_function) :: !call_inout_stack
      | `Memexec ->
        let table_current_function = CallsiteHash.create 7 in
        call_inout_stack :=
          (current_function, table_current_function) :: !call_inout_stack
      | `Spec | `Builtin { Value_types.c_from = None; _ } ->
        let inout = compute_using_prototype_state state current_function in
        merge_inout inout
    end

  module MemExec =
    State_builder.Hashtbl
      (Datatype.Int.Hashtbl)
      (Inout_type)
      (struct
        let size = 17
        let dependencies = [Internals.self]
        let name = "Operational_inputs.MemExecGraph"
      end)

  let end_record call_stack inout =
    merge_local_table_in_global_ones (snd (List.hd !call_inout_stack));
    let (current_function, _ as call_site) = List.hd call_stack in
    (* pop + record in top of stack the inout of function that just finished*)
    match !call_inout_stack with
    | (current_function2, _) :: (((_caller, table) :: _) as tail) ->
      if current_function2 != current_function then
        begin
          Inout_parameters.fatal "callwise inout %a != %a@."
            Kernel_function.pretty current_function (* g *)
            Kernel_function.pretty current_function2 (* f *)
        end;
      call_inout_stack := tail;
      merge_call_in_local_table call_site table inout;

    | _ ->  (* the entry point, probably *)
      merge_call_in_global_tables call_site inout;
      call_inout_stack := [];
      CallwiseResults.mark_as_computed ()

  let compute_call_from_graph kf graph =
    let module Builder = Nodegraph.Builder in
    let module Contracter = Vcontraction.Make(struct include Nodegraph include Builder end) in
    let graph = Contracter.contract (State_node.with_action (fun act -> match act with State_node.Init | State_node.Edge -> false | _ -> true)) graph in
    let initial_nodes = Nodegraph.fold_vertex
        (fun v acc -> match (State_node.action v) with State_node.Init -> State_node.Set.add v acc |_ -> acc)
        graph
        State_node.Set.empty
    in
    let module Fenv = (val Dataflows.function_env kf: Dataflows.FUNCTION_ENV) in
    let module GComputer = GComputer(Fenv)
        (struct
          let _version = "callwise with graph"
          let _kf = kf
          let graph = graph
          let initial_nodes = initial_nodes
          let at_call stmt kf =
            let _cur_kf, table = List.hd !call_inout_stack in
            try
              let with_internals = CallsiteHash.find table (kf, Kstmt stmt) in
              match kf.fundec with
              | Definition (fundec, _) ->
                let filter = Zone.filter_base
                    (fun b -> not (Base.is_formal_or_local b fundec))
                in
                Inout_type.map filter with_internals
              | _ -> with_internals
            with Not_found -> Inout_type.bottom
        end) in
    let module Compute = Dataflows.Simple_forward(Fenv)(GComputer) in
    GComputer.end_dataflow ()

  let record_for_callwise_inout ((call_stack: Db.Value.callstack), value_res) =
    if compute_callwise_graph () then
      let inout = match value_res with
        | Value_types.Normal (graph)
        | Value_types.NormalStore (graph, _) ->
          let kf = fst (List.hd call_stack) in
          let inout =
            if !Db.Value.no_results kf then
              top
            else
              compute_call_from_graph kf graph
          in
          Db.Operational_inputs.Record_Inout_Callbacks.apply
            (call_stack, inout);
          (match value_res with
           | Value_types.NormalStore (_, memexec_counter) ->
             MemExec.replace memexec_counter inout
           | _ -> ());
          inout
        | Value_types.Reuse counter ->
          MemExec.find counter
      in
      end_record call_stack inout

  let add_hooks () =
    Db.Value.Record_Value_Graph_Callbacks.extend_once record_for_callwise_inout;
    Db.Value.Call_Type_Value_Callbacks.extend_once call_for_callwise_inout

  let () =
    Inout_parameters.ForceCallwiseWithGraphInout.add_update_hook
      (fun _bold bnew -> if bnew then add_hooks ())

  let () =
    Inout_parameters.ForceCallwiseWithGraphInout.add_set_hook
      (fun bold bnew ->
         if bold = false && bnew then
           Project.clear
             ~selection:(State_selection.with_dependencies Db.Value.self) ())

end


(* Functionwise version of the computations. *)
module FunctionWise = struct

  (* Stack of function being processed *)
  let call_stack : kernel_function Stack.t = Stack.create ()

  let compute_internal_using_cfg kf =
    try
      let module Fenv =
        (val Dataflows.function_env kf: Dataflows.FUNCTION_ENV)
      in
      let module Computer = Computer(Fenv)(struct
          let _version = "functionwise"
          let _kf = kf
          let stmt_state = Db.Value.get_stmt_state
          let at_call stmt kf = get_external_aux ~stmt kf
        end) in
      Stack.iter
        (fun g -> if kf == g then begin
             if Db.Value.ignored_recursive_call kf then
               Inout_parameters.warning ~current:true
                 "During inout context analysis of %a:@ \
                  ignoring probable recursive call."
                 Kernel_function.pretty kf;
             raise Exit
           end)
        call_stack;
      Stack.push kf call_stack;

      let module Compute = Dataflows.Simple_forward(Fenv)(Computer) in
      let result = Computer.end_dataflow () in
      ignore (Stack.pop call_stack);
      result

    with Exit -> Inout_type.bottom (*TODO*) (*{
                                              Inout_type.over_inputs_if_termination = empty.over_inputs_d ;
                                              under_outputs_if_termination = empty.under_outputs_d;
                                              over_inputs = empty.over_inputs_d;
                                              over_outputs = empty.over_outputs_d;
                                              over_outputs_if_termination = empty.over_outputs_d;
                                              }*)

  let compute_internal_using_cfg kf =
    if !Db.Value.no_results kf then
      top
    else begin
      Inout_parameters.feedback ~level:2 "computing for function %a%s"
        Kernel_function.pretty kf
        (let s = ref "" in
         Stack.iter
           (fun kf -> s := !s^" <-"^
                           (Pretty_utils.sfprintf "%a" Kernel_function.pretty kf))
           call_stack;
         !s);
      let r = compute_internal_using_cfg kf in
      Inout_parameters.feedback ~level:2 "done for function %a"
        Kernel_function.pretty kf;
      r
    end
end


let get_internal =
  Internals.memo
    (fun kf ->
       !Db.Value.compute ();
       try Internals.find kf (* If [-inout-callwise] is set, the results may
                                have been computed by the call to Value.compute *)
       with
       | Not_found ->
         if!Db.Value.use_spec_instead_of_definition kf then
           compute_using_prototype kf
         else
           FunctionWise.compute_internal_using_cfg kf
    )

let raw_externals ~with_formals kf =
  let filter = externalize ~with_formals kf in
  filter (get_internal kf)

module Externals =
  Kernel_function.Make_Table(Inout_type)
    (struct
      let name = "External inouts full"
      let dependencies = [ Internals.self ]
      let size = 17
    end)
let get_external = Externals.memo (raw_externals ~with_formals:false)
let compute_external kf = ignore (get_external kf)



module Externals_With_Formals =
  Kernel_function.Make_Table(Inout_type)
    (struct
      let name = "External inouts with formals full"
      let dependencies = [ Internals.self ]
      let size = 17
    end)
let get_external_with_formals =
  Externals_With_Formals.memo (raw_externals ~with_formals:true)
let compute_external_with_formals kf = ignore (get_external_with_formals kf)


let pretty_operational_inputs_internal fmt kf =
  Format.fprintf fmt "@[InOut (internal) for function %a:@\n%a@]@\n"
    Kernel_function.pretty kf
    Inout_type.pretty_operational_inputs (get_internal kf)

let pretty_operational_inputs_external fmt kf =
  Format.fprintf fmt "@[InOut for function %a:@\n%a@]@\n"
    Kernel_function.pretty kf
    Inout_type.pretty_operational_inputs (get_external kf)

let pretty_operational_inputs_external_with_formals fmt kf =
  Format.fprintf fmt "@[InOut (with formals) for function %a:@\n%a@]@\n"
    Kernel_function.pretty kf
    Inout_type.pretty_operational_inputs (get_external_with_formals kf)



let () =
  Db.Operational_inputs.self_internal := Internals.self;
  Db.Operational_inputs.self_external := Externals.self;
  Db.Operational_inputs.get_internal := get_internal;
  Db.Operational_inputs.get_external := get_external;
  Db.Operational_inputs.get_internal_precise := get_internal_aux;
  Db.Operational_inputs.compute := compute_external;
  Db.Operational_inputs.display := pretty_operational_inputs_internal


(*
Local Variables:
compile-command: "make -C ../../.."
End:
*)
