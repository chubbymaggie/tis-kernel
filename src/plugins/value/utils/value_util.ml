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

open Cil_types

(* Callstacks related types and functions *)

(* Function called, and calling instruction. *)
type call_site = (kernel_function * kinstr)
type callstack =  call_site list

let call_stack = ref Value_callstack.Shared_callstack.empty
(* let call_stack_for_callbacks: (kernel_function * kinstr) list ref = ref [] *)

let clear_call_stack () =
  call_stack := Value_callstack.Shared_callstack.empty

let pop_call_stack () =
  Value_perf.stop_doing (Value_callstack.Shared_callstack.get !call_stack);
  call_stack := Value_callstack.Shared_callstack.pop !call_stack

let push_call_stack kf ki =
  call_stack := Value_callstack.Shared_callstack.push (kf,ki) !call_stack;
  Value_perf.start_doing (Value_callstack.Shared_callstack.get !call_stack)

let current_kf () =
  let (kf,_) = (List.hd (Value_callstack.Shared_callstack.get !call_stack)) in
  kf

let call_stack () = Value_callstack.Shared_callstack.get !call_stack

let pretty_call_stack_short fmt callstack =
  Pretty_utils.pp_flowlist ~left:"" ~sep:" <- " ~right:""
    (fun fmt (kf,_) -> Kernel_function.pretty fmt kf)
    fmt
    callstack

let pretty_call_stack fmt callstack =
  Format.fprintf fmt "@[<hv>";
  List.iter
    (fun (kf,ki) ->
       Kernel_function.pretty fmt kf;
       match ki with
       | Kglobal -> ()
       | Kstmt stmt ->
         Format.fprintf fmt " :: %a <-@ "
           Cil_datatype.Location.pretty (Cil_datatype.Stmt.loc stmt))
    callstack;
  Format.fprintf fmt "@]"

let pp_callstack fmt =
  if Value_parameters.PrintCallstacks.get () then
    Format.fprintf fmt "@ stack: %a"
      pretty_call_stack (call_stack())

let pp_callstack_or_dot fmt =
  if Value_parameters.PrintCallstacks.get () then
    Format.fprintf fmt "@ stack: %a"
      pretty_call_stack (call_stack())
  else Format.fprintf fmt "."

(* Misc *)

let get_rounding_mode () =
  if Value_parameters.AllRoundingModes.get ()
  then Fval.Any
  else Fval.Nearest_Even

let stop_if_stop_at_first_alarm_mode () =
  if Stop_at_nth.incr()
  then begin
    Value_parameters.log "Stopping at nth alarm" ;
    raise Db.Value.Aborted
  end

(* Assertions emitted during the analysis *)

let emitter =
  Emitter.create
    "Value"
    [ Emitter.Property_status; Emitter.Alarm ]
    ~correctness:Value_parameters.parameters_correctness
    ~tuning:Value_parameters.parameters_tuning

let () = Db.Value.emitter := emitter

let warn_all_mode = CilE.warn_all_mode

let with_alarm_stop_at_first =
  let stop =
    { warn_all_mode.CilE.others with
      CilE.a_call = stop_if_stop_at_first_alarm_mode }
  in
  { CilE.imprecision_tracing = CilE.a_ignore;
    defined_logic = stop;
    unspecified = stop;
    others = stop; }

let with_alarms_raise_exn exn =
  let raise_exn () = raise exn in
  let stop = { CilE.a_log = false; CilE.a_call = raise_exn } in
  { CilE.imprecision_tracing = CilE.a_ignore;
    defined_logic = stop;
    unspecified = stop;
    others = stop; }

let warn_all_quiet_mode () =
  if Value_parameters.StopAtNthAlarm.get () <> max_int
  then with_alarm_stop_at_first
  else
  if Value_parameters.verbose_atleast 1 then
    warn_all_mode
  else
    { warn_all_mode with CilE.imprecision_tracing = CilE.a_ignore }

let get_slevel kf =
  try Value_parameters.SlevelFunction.find kf
  with Not_found -> Value_parameters.SemanticUnrollingLevel.get ()

let get_tis_slevel_value state =
  (* 1. Get the __tis_slevel variable's value in the abstract state. *)
  let _, slevel_val =
    let scope = Cil_types.VGlobal in
    let slevel_varinfo =
      try Globals.Vars.find_from_astinfo "__tis_slevel" scope
      with Not_found ->
        Value_parameters.abort "The slevel parameter is equal -1, but there is \
                                no global `__tis_slevel' variable."
    in
    let slevel_val_loc = Locations.loc_of_varinfo slevel_varinfo in
    Cvalue.Model.find state slevel_val_loc
    (* NOTE: Cvalue.Model.find could in theory return bottom, but here it is
             impossible (as the global variable was found at this point), so we
             do not check for this case. *)
  in
  (* 2. Check if the value is valid and project it to int. *)
  try
    let slevel_ival = Cvalue.V.project_ival slevel_val in
    let slevel_integer = Ival.project_int slevel_ival in
    let slevel_int = Abstract_interp.Int.to_int slevel_integer in
    if slevel_int < 0 then
      Value_parameters.abort "The `__tis_slevel' variable's value is negative.";
    slevel_int
  with
  | Cvalue.V.Not_based_on_null ->
    Value_parameters.abort "The `__tis_slevel' variable is an address."
  | Ival.Not_Singleton_Int ->
    Value_parameters.abort "The `__tis_slevel' variable is imprecise."
  | Failure msg ->
    assert (msg = "int_of_big_int");
    Value_parameters.abort "The `__tis_slevel' variable's value is too large."

let set_loc kinstr =
  match kinstr with
  | Kglobal -> Cil.CurrentLoc.clear ()
  | Kstmt s -> Cil.CurrentLoc.set (Cil_datatype.Stmt.loc s)

let pretty_actuals fmt actuals =
  let pp fmt (e,x,_) = Cvalue.V.pretty_typ (Some (Cil.typeOf e)) fmt x in
  Pretty_utils.pp_flowlist pp fmt actuals

let pretty_current_cfunction_name fmt =
  Kernel_function.pretty fmt (current_kf())

let warning_once_current fmt =
  Value_parameters.warning ~current:true ~once:true fmt

let debug_result kf (last_ret,_,last_clob) =
  Value_parameters.debug
    "@[RESULT FOR %a <-%a:@\n\\result -> %t@\nClobered set:%a@]"
    Kernel_function.pretty kf
    pretty_call_stack (call_stack ())
    (fun fmt ->
       match last_ret with
       | None -> ()
       | Some v -> Cvalue.V_Offsetmap.pretty fmt v)
    Base.SetLattice.pretty last_clob


(* The callstack where the degeneration occurs *)
module Degeneration =
  State_builder.Option_ref
    (Datatype.Pair
       (Cil_datatype.Stmt)
       (Value_callstack.Callstack))
    (struct
      let name = "Value_util.Degeneration"
      let dependencies = [ Db.Value.self ]
    end)
let () = Ast.add_monotonic_state Degeneration.self
(* The stmt where the degeneration occurs and statements above in the
   callstack *)
module DegenerationPoints =
  State_builder.Option_ref
    (Cil_datatype.Stmt.Set)
    (struct
      let name = "Value_util.DegenerationPoints"
      let dependencies = [ Degeneration.self ]
    end)
let () = Ast.add_monotonic_state DegenerationPoints.self

(* Table of unpropagated stmts with their callstacks *)
module UnpropagatedPoints =
  Cil_state_builder.Stmt_hashtbl
    (Value_callstack.Callstack.Set)
    (struct
      let name = "Value_util.UnpropagatedPoints"
      let size = 17
      let dependencies = [ Db.Value.self ]
    end)
let () = Ast.add_monotonic_state UnpropagatedPoints.self

let reset_degeneration_points () =
  Degeneration.clear ();
  DegenerationPoints.clear ();
  UnpropagatedPoints.clear ()

let register_degeneration_point stmt callstack =
  if Degeneration.get_option () <> None then
    Value_parameters.fatal "Cannot register a degeneration point twice";
  Degeneration.set (stmt,callstack)

let get_degeneration_point = Degeneration.get_option

let is_stmt_degenerated stmt =
  let f () =
    match Degeneration.get_option () with
    | None -> Cil_datatype.Stmt.Set.empty
    | Some (s,cs) ->
      List.fold_left
        (fun acc (_,ki) ->
           match ki with
           | Kglobal -> acc
           | Kstmt stmt -> Cil_datatype.Stmt.Set.add stmt acc)
        (Cil_datatype.Stmt.Set.singleton s) cs
  in
  Cil_datatype.Stmt.Set.mem stmt (DegenerationPoints.memo f)


module JoinPoints =
  Cil_state_builder.Stmt_hashtbl
    (Datatype.Pair
       (Value_callstack.Callstack.Hashtbl.Make
          (Datatype.Triple(Datatype.Int)(Datatype.Int)(Datatype.Int)))
       (Datatype.Int))
    (struct
      let name = "Value_util.LostPrecision"
      let size = 17
      let dependencies = [ Db.Value.self ]
    end)
let () = Ast.add_monotonic_state JoinPoints.self

let warn_indeterminate kf =
  let params = Value_parameters.WarnCopyIndeterminate.get () in
  Kernel_function.Set.mem kf params

let register_new_var v typ =
  if Cil.isFunctionType typ then
    Globals.Functions.replace_by_declaration (Cil.empty_funspec()) v v.vdecl
  else
    Globals.Vars.add_decl v

let create_new_var name typ =
  let vi = Cil.makeGlobalVar ~source:false ~temp:false name typ in
  register_new_var vi typ;
  vi

let is_const_write_invalid typ =
  Kernel.ConstReadonly.get () && Cil.typeHasQualifier "const" typ

let float_kind = function
  | FFloat -> Fval.Float32
  | FDouble -> Fval.Float64
  | FLongDouble ->
    if Cil.theMachine.Cil.theMachine.sizeof_longdouble <> 8 then
      Value_parameters.error ~once:true
        "type long double not implemented. Using double instead";
    Fval.Float64

(* Find if a postcondition contains [\result] *)
class postconditions_mention_result = object
  inherit Visitor.frama_c_inplace

  method! vterm_lhost = function
    | TResult _ -> raise Exit
    | _ -> Cil.DoChildren
end
let postconditions_mention_result spec =
  (* We save the current location because the visitor modifies it. *)
  let loc = Cil.CurrentLoc.get () in
  let vis = new postconditions_mention_result in
  let aux_bhv bhv =
    let aux (_, post) = ignore (Visitor.visitFramacIdPredicate vis post) in
    List.iter aux bhv.b_post_cond
  in
  let res =
    try
      List.iter aux_bhv spec.spec_behavior;
      false
    with Exit -> true
  in
  Cil.CurrentLoc.set loc;
  res

let written_formals kf =
  let module S = Cil_datatype.Varinfo.Set in
  match kf.fundec with
  | Declaration _ -> S.empty
  | Definition (fdec,  _) ->
    let add_addr_taken acc vi = if vi.vaddrof then S.add vi acc else acc in
    let referenced_formals =
      ref (List.fold_left add_addr_taken S.empty fdec.sformals)
    in
    let obj = object
      inherit Visitor.frama_c_inplace

      method! vinst i =
        begin match i with
          | Call (Some (Var vi, _), _, _, _)
          | Set ((Var vi, _), _, _) ->
            if Kernel_function.is_formal vi kf then
              referenced_formals := S.add vi !referenced_formals
          | _ -> ()
        end;
        Cil.SkipChildren
    end
    in
    ignore (Visitor.visitFramacFunction (obj :> Visitor.frama_c_visitor) fdec);
    !referenced_formals

module WrittenFormals =
  Kernel_function.Make_Table(Cil_datatype.Varinfo.Set)
    (struct
      let size = 17
      let dependencies = [Ast.self]
      let name = "Value_util.WrittenFormals"
    end)
let () = Ast.add_monotonic_state WrittenFormals.self

let written_formals = WrittenFormals.memo written_formals


let bind_local_state vi state =
  let b = Base.of_varinfo vi in
  match Cvalue.Default_offsetmap.default_offsetmap b with
  | `Bottom -> state
  | `Map offsm ->
    (* Bind [vi] in [state] *)
    Cvalue.Model.add_base b offsm state

let bind_block_locals states b =
  (* Bind [vi] in [states] *)
  let bind_local_stateset states vi =
    State_set.map (bind_local_state vi) states
  in
  List.fold_left bind_local_stateset states b.blocals

let bind_locals_state st b =
  List.fold_left (fun st vi -> bind_local_state vi st) st b.blocals

let conv_comp op =
  let module C = Abstract_interp.Comp in
  match op with
  | Eq -> C.Eq
  | Ne -> C.Ne
  | Le -> C.Le
  | Lt -> C.Lt
  | Ge -> C.Ge
  | Gt -> C.Gt
  | _ -> assert false

let conv_relation rel =
  let module C = Abstract_interp.Comp in
  match rel with
  | Req -> C.Eq
  | Rneq -> C.Ne
  | Rle -> C.Le
  | Rlt -> C.Lt
  | Rge -> C.Ge
  | Rgt -> C.Gt

(* Test that two functions types are compatible; used to verify that a call
   through a function pointer is ok. In theory, we could only check that
   both types are compatible as defined by C99, 6.2.7. However, some industrial
   codes do not strictly follow the norm, and we must be more lenient.
   Thus, we emit a warning on undefined code, but we also return true
   if Value can ignore more or less safely the incompatibleness in the types. *)
let compatible_functions ~with_alarms vi typ_pointer typ_fun =
  try
    ignore (Cabs2cil.compatibleTypes typ_pointer typ_fun); true
  with Failure _ ->
    let compatible_sizes t1 t2 =
      try Cil.bitsSizeOf t1 = Cil.bitsSizeOf t2
      with Cil.SizeOfError _ -> false
    in
    let continue = match Cil.unrollType typ_pointer, Cil.unrollType typ_fun with
      | TFun (ret1, args1, var1, _), TFun (ret2, args2, var2, _) ->
        (* Either both functions are variadic, or none. Otherwise, it
           will be too complicated to make the argument match *)
        var1 = var2 &&
        (* Both functions return something of the same size, or nothing*)
        (match Cil.unrollType ret1, Cil.unrollType ret2 with
         | TVoid _, TVoid _ -> true (* let's avoid relying on the size
                                       of void *)
         | TVoid _, _ | _, TVoid _ -> false
         | t1, t2 -> compatible_sizes t1 t2
        ) &&
        (* Argument lists of the same length, with compatible sizes between
           the arguments, or unspecified argument lists *)
        (match args1, args2 with
         | None, None | None, Some _ | Some _, None -> true
         | Some lp, Some lf ->
           (* See corresponding function fold_left2_best_effort in
              Function_args *)
           let rec comp lp lf = match lp, lf with
             | _, [] -> true (* accept too many arguments passed *)
             | [], _ :: _ -> false (* fail on too few arguments *)
             | (_, tp, _) :: qp, (_, tf, _) :: qf ->
               compatible_sizes tp tf && comp qp qf
           in
           comp lp lf
        )
      | _ -> false
    in
    if with_alarms.CilE.others.CilE.a_log then
      warning_once_current
        "@[Function@ pointer@ and@ pointed@ function@ '%a'@ have@ %s\
         incompatible@ types:@ %a@ vs.@ %a.@ assert(function type matches)@]%t"
        Printer.pp_varinfo vi
        (if continue then "" else "completely ")
        Printer.pp_typ typ_pointer Printer.pp_typ typ_fun
        pp_callstack;
    continue

let loc_dummy_value =
  let l = { Lexing.dummy_pos with Lexing.pos_fname = "_value_" } in
  l, l

let zero e =
  let loc = loc_dummy_value in
  match Cil.unrollType (Cil.typeOf e) with
  | TFloat (fk, _) -> Cil.new_exp ~loc (Const (CReal (0., fk, None)))
  | TEnum ({ ekind = ik; _ },_)
  | TInt (ik, _) -> Cil.new_exp ~loc (Const (CInt64 (Integer.zero, ik, None)))
  | TPtr _ ->
    let ik = Cil.(theMachine.upointKind) in
    Cil.new_exp ~loc (Const (CInt64 (Integer.zero, ik, None)))
  | typ -> Value_parameters.fatal ~current:true "non-scalar type %a"
             Printer.pp_typ typ

let is_value_zero e =
  e.eloc == loc_dummy_value

(* Definitions related to malloc builtins *)
module Dynamic_Allocations =
struct
  module Dynamic_Alloc_Bases =
    State_builder.Array
      (Base.Hptset)
      (struct
        let dependencies = [Ast.self] (* TODO: should probably depend on Value
                                         itself *)
        let name = "Dynamic_Alloc_Bases"
        let default = Base.Hptset.empty
        let default_length = 3
      end)
  let () = Ast.add_monotonic_state Dynamic_Alloc_Bases.self
  let allocation_functions i =
    (fun b ->
       Dynamic_Alloc_Bases.set i (Base.Hptset.add
                                    b
                                    (Dynamic_Alloc_Bases.get i))),
    (fun  () -> Dynamic_Alloc_Bases.get i)
  let register_malloc_base, malloc_bases = allocation_functions 0
  let register_new_base, new_bases = allocation_functions 1
  let register_new_array_base, new_array_bases = allocation_functions 2
  let allocated_bases () =
    Dynamic_Alloc_Bases.fold_left Base.Hptset.union Base.Hptset.empty
end
let is_function_variadic kf =
  let typ = Cil.unrollType (Kernel_function.get_type kf) in
  match typ with
  | TFun (_result_typ, _formal_args, is_variadic, _attributes) -> is_variadic
  | _ -> assert false (* The type of a function must be a function type... *)


(*
Local Variables:
compile-command: "make -C ../../../.."
End:
*)
