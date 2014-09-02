open Form
open FormUtil
open Prog
open Simplify
open Grassify

(** Infer sets of accessed and modified variables *)
(* TODO: the implementation of the fix-point loop is brain damaged - rather use a top. sort of the call graph *)
let infer_accesses prog =
  let rec pm prog = function
    | Loop (lc, pp) ->
        let has_new1, prebody1 = pm prog lc.loop_prebody in
        let has_new2, postbody1 = pm prog lc.loop_postbody in
        has_new1 || has_new2, 
        mk_loop_cmd lc.loop_inv prebody1 lc.loop_test lc.loop_test_pos postbody1 pp.pp_pos
    | Choice (cs, pp) ->
        let has_new, mods, accs, cs1 = 
          List.fold_right 
            (fun c (has_new, mods, accs, cs1) ->
              let has_new1, c1 = pm prog c in
              has_new1 || has_new, 
              IdSet.union (modifies c1) mods, 
              IdSet.union (accesses c1) accs, 
              c1 :: cs1)
            cs (false, IdSet.empty, IdSet.empty, [])
        in
        let pp1 = {pp with pp_modifies = mods; pp_accesses = accs} in
        has_new, Choice (cs1, pp1)
    | Seq (cs, pp) ->
        let has_new, mods, accs, cs1 = 
          List.fold_right 
            (fun c (has_new, mods, accs, cs1) ->
              let has_new1, c1 = pm prog c in
              has_new1 || has_new, 
              IdSet.union (modifies c1) mods, 
              IdSet.union (accesses c1) accs, 
              c1 :: cs1)
            cs (false, IdSet.empty, IdSet.empty, [])
        in
        let pp1 = {pp with pp_modifies = mods; pp_accesses = accs} in
        has_new, Seq (cs1, pp1)
    | Basic (Call cc, pp) ->
        let callee = find_proc prog cc.call_name in
        let mods = modifies_proc prog callee in
        let accs = accesses_proc prog callee in
        let has_new = 
          not (IdSet.subset mods pp.pp_modifies) ||  
          not (IdSet.subset accs pp.pp_accesses)
        in
        let pp1 = {pp with pp_modifies = mods; pp_accesses = accs} in
        has_new, Basic (Call cc, pp1)
    | c ->  false, c
  in
  let pm_pred prog pred =
    let accs_preds, body_accs =
      match pred.pred_body.spec_form with
      | SL f -> 
          let accs_preds = SlUtil.preds f in
          let accs = SlUtil.free_consts f in
          accs_preds, accs
      | FOL f -> IdSet.empty, free_consts f
    in
    let accs = 
      IdSet.fold (fun p -> 
        let opred = find_pred prog p in
        IdSet.union opred.pred_accesses)
        accs_preds body_accs
    in
    let global_accs = 
      IdSet.filter (fun id -> IdMap.mem id prog.prog_vars) accs
    in
    not (IdSet.subset global_accs pred.pred_accesses),
    { pred with pred_accesses = global_accs }
  in
  let rec pm_prog prog = 
    let procs = procs prog in
    let has_new, procs1 =
      List.fold_left 
        (fun (has_new, procs1) proc ->
          match proc.proc_body with
          | Some body ->
              let has_new1, body1 = pm prog body in
              let proc1 = {proc with proc_body = Some body1} in
              (has_new || has_new1, proc1 :: procs1)
          | None -> (has_new, proc :: procs1))
        (false, []) procs
    in 
    let procs2 = 
      List.fold_left 
      (fun procs2 proc -> IdMap.add proc.proc_name proc procs2) 
      IdMap.empty procs1
    in
    let preds = preds prog in
    let has_new, preds1 = 
      List.fold_left 
        (fun (has_new, preds1) pred ->
          let has_new1, pred1 = pm_pred prog pred in
          (has_new || has_new1, pred1 :: preds1))
        (has_new, []) preds
    in
    let preds2 = 
      List.fold_left 
        (fun preds2 pred -> IdMap.add pred.pred_name pred preds2)
        IdMap.empty preds1
    in
    let prog1 = 
      { prog with 
        prog_procs = procs2;
        prog_preds = preds2 
      } in
    if has_new then pm_prog prog1 else prog1 
  in
  pm_prog prog

(** Simplify the given program by applying all transformation steps. *)
let simplify prog =
  let dump_if n prog = 
    if !Config.dump_ghp == n 
    then print_prog stdout prog 
    else ()
  in
  dump_if 0 prog;
  Debug.info (fun () -> "Inferring accesses, eliminating loops and global dependencies.\n");
  let prog = infer_accesses prog in
  let prog = elim_loops prog in
  let prog = elim_global_deps prog in
  dump_if 1 prog;
  Debug.info (fun () -> "Eliminating SL, adding heap access checks, and eliminating new/dispose.\n");
  let prog = elim_sl prog in
  let prog = annotate_heap_checks prog in
  let prog = elim_new_dispose prog in
  dump_if 2 prog;
  Debug.info (fun () -> "Eliminating return statements and transforming to SSA form.\n");
  let prog = elim_return prog in
  let prog = elim_state prog in
  dump_if 3 prog;
  prog

(** Generate predicate instances *)
let add_pred_insts prog f =
  let mk_instance pos p ts =
    let pred = find_pred prog p in
    let sm = 
      List.fold_left2 
        (fun sm id t -> IdMap.add id t sm)
        IdMap.empty (pred.pred_formals) ts
    in
    let sm =
      match pred.pred_returns with
      | [] -> sm
      | [id] -> 
          let var = IdMap.find id pred.pred_locals in
          IdMap.add id (mk_free_fun var.var_sort p ts) sm
      | _ -> failwith "Functions may only have a single return value."
    in
    let body = match pred.pred_body.spec_form with
    | FOL f -> subst_consts sm f
    | SL f -> failwith "SL formula should have been desugared"
    in
    if pos
    then 
      match pred.pred_returns with
      | [] -> mk_implies (mk_pred p ts) body
      | _ -> body
    else mk_not body
  in
  let pos_preds = 
    let rec collect_term pos = function
      | App (FreeSym p, ts, _) as t ->
          let pos = List.fold_left collect_term pos ts in
          if IdMap.mem p prog.prog_preds 
          then TermSet.add t pos
          else pos
      | App (_, ts, _) -> 
          List.fold_left collect_term pos ts
      | _ -> pos
    in
    let rec collect pos = function
      | Binder (_, [], f, _) -> collect pos f
      | BoolOp (And, fs)
      | BoolOp (Or, fs) ->
          List.fold_left collect pos fs
      (*| BoolOp (Not, [Atom (App (FreeSym p, _, _) as t)]) ->
          if IdMap.mem p prog.prog_preds 
          then (pos, TermSet.add t neg)
          else (pos, neg)*)
      | Atom (App (FreeSym p, _, _) as t, _) -> 
          if IdMap.mem p prog.prog_preds 
          then TermSet.add t pos
          else pos
      | BoolOp (Not, [Atom (t, _)])
      | Atom (t, _) -> collect_term pos t
      | _ -> pos
    in collect TermSet.empty f 
  in
  let pos_instances = 
    TermSet.fold (fun t instances ->
      match t with
      | App (FreeSym p, ts, _) -> mk_instance true p ts :: instances
      | _ -> instances)
      pos_preds []
  in
  let f_inst = 
    let rec inst_neg_preds = function
      | Binder (b, [], f, a) -> 
          Binder (b, [], inst_neg_preds f, a)
      | BoolOp (And as op, fs)
      | BoolOp (Or as op, fs) ->
          let fs_inst = List.map inst_neg_preds fs in
          BoolOp (op, fs_inst)
      | BoolOp (Not, [Atom (App (FreeSym p, ts, _), a)]) 
        when IdMap.mem p prog.prog_preds ->
          annotate (mk_instance false p ts) a
      | f -> f
    in inst_neg_preds f
  in
  smk_and (f_inst :: pos_instances)

let add_labels vc =
  let rec get_comment = function
    | Comment c :: _ -> Some c
    | _ :: annots -> get_comment annots
    | [] -> None
  in
  let process_annot c (ltop, annots) ann =
    match ann, c with
    | SrcPos pos, Some c -> 
        let lbl = fresh_ident "Label" in
        IdMap.add lbl (pos, "Related Location: " ^ c) ltop, 
        Label lbl :: ann :: annots
    | _ -> ltop, ann :: annots
  in
  let rec al f ltop = 
    match f with
    | BoolOp (op, fs) -> 
        let ltop1, fs1 = 
          List.fold_right (fun f (ltop, fs1) -> 
            let ltop1, f1 = al f ltop in
            ltop1, f1 :: fs1) fs (ltop, [])
        in
        ltop1, BoolOp (op, fs1)
    | Binder (b, vs, f, annots) ->
        let c = get_comment annots in
        let ltop1, f1 = al f ltop in
        let ltop2, annots1 = List.fold_left (process_annot c) (ltop1, []) annots in
        ltop2, Binder (b, vs, f1, annots1)
    | Atom (t, annots) -> 
        let c = get_comment annots in
        let ltop1, annots1 = List.fold_left (process_annot c) (ltop, []) annots in
        ltop1, Atom (t, annots1)
  in
  al vc IdMap.empty

(** Generate verification conditions for given procedure. 
 ** Assumes that proc has been transformed into SSA form. *)
let vcgen prog proc =
  let rec vcs acc pre = function
    | Loop _ -> 
        failwith "vcgen: loop should have been desugared"
    | Choice (cs, pp) ->
        let acc1, traces = 
          List.fold_left (fun (acc, traces) c ->
            let acc1, trace = vcs acc pre c in
            acc1, trace :: traces)
            (acc, []) cs
        in acc1, [smk_or (List.rev_map smk_and traces)]
    | Seq (cs, pp) -> 
        let acc1, trace, _ = 
          List.fold_left (fun (acc, trace, pre) c ->
            let acc1, c_trace = vcs acc pre c in
            acc1, trace @ c_trace, pre @ c_trace)
            (acc, [], pre) cs 
        in
        acc1, trace
    | Basic (bc, pp) ->
        match bc with
        | Assume s ->
            let name = 
              Printf.sprintf "%s_%d_%d" 
                s.spec_name pp.pp_pos.sp_start_line pp.pp_pos.sp_start_col
            in
            (match s.spec_form with
              | FOL f -> acc, [mk_name name f]
              | _ -> failwith "vcgen: found SL formula that should have been desugared")
        | Assert s ->
            let rec annotate_aux_msg msg = 
              let annotate annot = 
                if List.exists (function SrcPos _ -> true | _ -> false) annot
                then Comment msg :: annot
                else annot
              in
              function
                | BoolOp (op, fs) -> 
                    BoolOp (op, List.map (annotate_aux_msg msg) fs)
                | Binder (b, vs, f, annot) ->
                    Binder (b, vs, annotate_aux_msg msg f, annotate annot)
                | Atom (t, annot) -> Atom (t, annotate annot)
            in
            let name = 
              Printf.sprintf "%s_%d_%d" 
                s.spec_name pp.pp_pos.sp_start_line pp.pp_pos.sp_start_col
            in
            let vc_msg, vc_aux_msg = 
              match s.spec_msg with
              | None -> 
                  "Possible assertion violation.", 
                  "This is the assertion that might be violated"
              | Some msg -> msg proc.proc_name
            in 
            let vc_msg = (vc_msg, pp.pp_pos) in
            let f =
              match s.spec_form with
              | FOL f -> annotate_aux_msg vc_aux_msg (unoldify_form (mk_not f))
              | _ -> failwith "vcgen: found SL formula that should have been desugared"
            in
            let vc_name = 
              Str.global_replace (Str.regexp " ") "_"
                (string_of_ident proc.proc_name ^ "_" ^ name)
            in
            let vc = pre @ [mk_name name f] in
            (vc_name, vc_msg, smk_and vc) :: acc, []
        | _ -> 
            failwith "vcgen: found unexpected basic command that should have been desugared"
  in
  match proc.proc_body with
  | Some body -> List.rev (fst (vcs [] [] body))
  | None -> []

let split_vc prog vc_name f =
  let rec split vcs = function
    | BoolOp(And, fs) :: fs1 -> 
        split vcs (fs @ fs1)
    | BoolOp(Or, fs) :: fs1 ->
        let fsa, fsb = List.fold_right (fun f (fsa, fsb) -> (fsb, f :: fsa)) fs ([], []) in
        let f1 = match fsa with
        | [] -> smk_or fsb
        | fsa -> 
            begin
              let vc = smk_and (vcs @ smk_or fsa :: fs1) in
              match Prover.check_sat ~session_name:vc_name (add_pred_insts prog vc) with
              | Some false -> smk_or fsb
              | _ -> smk_or fsa
            end
        in
        split vcs (f1 :: fs1)
    | Binder (b, [], Binder (_, [], f, a2), a1) :: fs1 ->
        split vcs (Binder (b, [], f, a1 @ a2) :: fs1)
    | Binder (b, [], BoolOp(And as op, fs), a) :: fs1
    | Binder (b, [], BoolOp(Or as op, fs), a) :: fs1 ->
        let f1 = BoolOp(op, List.map (fun f -> Binder (b, [], f, a)) fs) in
        split vcs (f1 :: fs1)
    | f :: fs1 -> split (f :: vcs) fs1
    | [] -> smk_and vcs
  in 
  let min_vc = split [] [f] in
  ignore (Prover.check_sat ~session_name:vc_name (add_pred_insts prog min_vc))

(** Generate verification conditions for given procedure and check them. *)
let check_proc prog proc =
  let check_vc (vc_name, (vc_msg, pp), vc0) =
    let vc1 = skolemize (propagate_exists (foralls_to_exists (nnf vc0))) in
    let labels, vc = add_labels vc1 in
    (*let _ = print_form stdout vc in*)
    let check_one vc =
      let vc_and_preds = add_pred_insts prog vc in
      Debug.info (fun () -> "Checking VC: " ^ vc_name ^ ".\n");
      Debug.debug (fun () -> (string_of_form vc_and_preds) ^ "\n");
      let sat_means = 
        Str.global_replace (Str.regexp "\n\n") "\n  " (ProgError.error_to_string pp vc_msg)
      in
      match Prover.get_model ~session_name:vc_name ~sat_means:sat_means vc_and_preds with
      | None -> []
      | Some model -> 
          (* generate error message from model *)
          let add_msg pos msg error_msgs =
            let filtered_msgs = 
              List.filter 
                (fun (pos2, _) -> not (contained_in_src_pos pos pos2))
                error_msgs
            in
            (pos, msg) :: filtered_msgs
          in
          let error_msgs = 
            IdMap.fold 
              (fun id (pos, msg) error_msgs ->
                let p = mk_free_const Bool id in
                match Model.eval_bool_opt model p with
                | Some true ->
                    add_msg pos msg error_msgs
                | _ -> error_msgs
              ) 
              labels []
          in
          let sorted_error_msgs = 
            List.sort
              (fun (pos1, _) (pos2, _) -> compare_src_pos pos1 pos2) 
              error_msgs 
          in
          let error_msg_strings = 
            List.map 
              (fun (pos, msg) -> ProgError.error_to_string pos msg) 
              sorted_error_msgs
          in
          let error_msg =
            String.concat "\n\n" (vc_msg :: error_msg_strings)
          in
          [(pp, error_msg, model)]
    in check_one vc
  in
  let vcs = vcgen prog proc in
  Util.flat_map check_vc vcs

(** Generate a counterexample trace from a failed VC and model *)
let get_trace prog proc (pp, model) =
  let add (pos, state) = function
    | (prv_pos, prv_state) :: trace ->
        if prv_pos = pos 
        then (prv_pos, prv_state) :: trace
        else (pos, state) :: (prv_pos, prv_state) :: trace
    | [] -> [(pos, state)]
  in
  let rec update_vmap (vmap, all_aux) = function
    | Atom (App (Eq, [App (FreeSym (name, num), [], _); _], _), _) ->
        let decl = find_var prog proc (name, num) in
        IdMap.add (name, 0) (name, num) vmap,
        decl.var_is_aux && all_aux
    | BoolOp (And, fs) ->
        List.fold_left update_vmap (vmap, all_aux) fs
    | Binder (_, [], f, _) -> 
        update_vmap (vmap, all_aux) f
    | _ -> vmap, all_aux
  in
  let get_curr_state pos vmap model =
    let ids = 
      IdMap.fold 
        (fun _ id ids -> 
          let decl = find_var prog proc id in
          if decl.var_is_aux && name id <> "FP" && name id <> "Alloc" || 
             not (contained_in_src_pos pos decl.var_scope) 
          then ids
          else IdSet.add id ids) 
        vmap IdSet.empty 
    in
    let rmodel = Model.restrict_to_idents model ids in
    Model.rename_free_symbols rmodel (fun (name, _) -> (name, 0))
  in
  let rec gt vmap trace = function
    | Choice (cs, pp) :: cs1 ->
        Util.flat_map (gt vmap trace) (List.map (fun c -> c :: cs1) cs)
    | Seq (cs, pp) :: cs1 -> 
        gt vmap trace (cs @ cs1)
    | Basic (bc, _)  :: cs1 ->
        (match bc with
        | Assume s ->
            (match s.spec_name with
            | "assign" | "if_then" | "if_else" | "havoc" ->
                let f = form_of_spec s in
                (match Model.eval_form model f with
                | None -> 
                    (*print_string "Ignoring command: ";
                    print_endline (Form.string_of_src_pos s.spec_pos);
                    Prog.print_cmd stdout c;
                    print_newline ();*)
                    gt vmap trace cs1
                | Some true -> 
                    (*print_string "Adding command: ";
                    print_endline (Form.string_of_src_pos s.spec_pos);
                    Prog.print_cmd stdout c;
                    print_newline ();*)
                    let curr_state = get_curr_state s.spec_pos vmap model in
                    if s.spec_name = "assign" || s.spec_name = "havoc"
                    then 
                      let vmap1, all_aux = update_vmap (vmap, true) f in
                      let trace1 = 
                        if all_aux 
                        then trace 
                        else add (s.spec_pos, curr_state) trace
                      in
                      gt vmap1 trace1 cs1
                    else gt vmap (add (s.spec_pos, curr_state) trace) cs1
                | Some false -> 
                    (* print_string "Dropping trace on assume: ";
                    print_endline (Form.string_of_src_pos s.spec_pos);
                    Prog.print_cmd stdout c;
                    print_newline (); *)
                    [])
            | "join" -> 
                let vmap1, _ = update_vmap (vmap, true) (form_of_spec s) in
                gt vmap1 trace cs1
            | _ -> gt vmap trace cs1)
        | Assert s ->
            if pp = s.spec_pos
            then 
              let curr_state = get_curr_state pp vmap model in
              List.rev ((pp, curr_state) :: trace)
            else gt vmap trace cs1
        | _ -> gt vmap trace cs1)
    | _ :: cs1 -> gt vmap trace cs1
    | [] -> 
        let curr_state = get_curr_state pp vmap model in
        List.rev ((pp, curr_state) :: trace)
  in 
  let init_vmap =
    let vars = IdMap.merge (fun id v1 v2 ->
      match v1, v2 with
      | Some v1, _ -> Some v1
      | _, Some v2 -> Some v2
      | _, _ -> None) prog.prog_vars proc.proc_locals
    in
    IdMap.fold 
      (fun (name, num) _ vmap -> 
        try 
          if snd (IdMap.find (name, 0) vmap) > num 
          then IdMap.add (name, 0) (name, num) vmap
          else vmap
        with Not_found -> IdMap.add (name, 0) (name, num) vmap)
      vars IdMap.empty
  in
  match gt init_vmap [] (Util.Opt.to_list proc.proc_body) with
  | _ :: trace -> trace
  | [] -> []
