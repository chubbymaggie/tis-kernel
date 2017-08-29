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
(*  This file is part of WP plug-in of Frama-C.                           *)
(*                                                                        *)
(*  Copyright (C) 2007-2015                                               *)
(*    CEA (Commissariat a l'energie atomique et aux energies              *)
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

open Wpo

(* -------------------------------------------------------------------------- *)
(* --- Verification Conditions Interface                                  --- *)
(* -------------------------------------------------------------------------- *)
type t = Wpo.t

let get_id = Wpo.get_gid
let get_model = Wpo.get_model
let get_description = Wpo.get_label
let get_property = Wpo.get_property
let get_result = Wpo.get_result
let get_results = Wpo.get_results
let get_logout = Wpo.get_file_logout
let get_logerr = Wpo.get_file_logerr
let is_trivial = Wpo.is_trivial

let pp_goal fmt t = Wpo.pp_goal fmt t
let pp_title fmt t = Wpo.pp_title fmt t
let pp_index fmt t = Wpo.pp_index fmt (Wpo.get_index t)
let pp_name fmt t = Format.pp_print_string fmt t.po_name

let get_formula po =
  match po.po_formula with
  | GoalLemma l -> l.VC_Lemma.lemma.Definitions.l_lemma
  | GoalAnnot a -> Wpo.GOAL.compute_proof a.VC_Annot.goal
  | GoalCheck c -> c.VC_Check.goal

let clear = Wpo.clear
let proof = Wpo.goals_of_property
let iter_ip on_goal ip = Wpo.iter ~ip ~on_goal ()
let iter_kf on_goal ?bhv kf =
  match bhv with
  | None ->
    (* iter on all behaviors, see Wpo.iter *)
    Wpo.iter ~index:(Wpo.IFunction (kf, None)) ~on_goal ()
  | Some bs ->
    List.iter
      (fun b ->
         Wpo.iter ~index:(Wpo.IFunction (kf, Some b)) ~on_goal ()
      ) bs

let iter_goals = Wpo.iter_on_goals

let remove = iter_ip Wpo.remove
let () = Property_status.register_property_remove_hook remove

(* -------------------------------------------------------------------------- *)
(* --- Generator Interface                                                --- *)
(* -------------------------------------------------------------------------- *)

let generator ?model () =
  let setup = match model with
    | None -> Register.cmdline ()
    | Some s -> Factory.parse [s] in
  let driver = Driver.load_driver () in
  CfgWP.computer setup driver

let generate_ip ?model ip =
  let gen = generator ?model () in
  Generator.compute_ip gen ip

let generate_kf ?model ?(bhv=[]) kf =
  let gen = generator ?model () in
  Generator.compute_kf gen ~bhv ~kf ()

let generate_call ?model stmt =
  let gen = generator ?model () in
  Generator.compute_call gen stmt

(* -------------------------------------------------------------------------- *)
(* --- Prover Interface                                                   --- *)
(* -------------------------------------------------------------------------- *)

let prove = Prover.prove
let spawn = Prover.spawn
let server = ProverTask.server
let command vcs = Register.do_wp_proofs_iter (fun f -> Bag.iter f vcs)

(* -------------------------------------------------------------------------- *)
