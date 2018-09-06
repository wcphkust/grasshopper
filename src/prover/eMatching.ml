(** E-Matching.

  Implements a variant of the E-matching technique presented in this paper:
      Efficient E-Matching for SMT Solvers
      Leonardo de Moura and Nikolaj Bjorner, CADE 2007

*)

open Util
open Grass
open GrassUtil

module CC = CongruenceClosure


(** Top-level symbol of current pattern to be matched.
 *  If we are matching a trivial pattern consisting only of 
 *  a variable, we only record its sort, hence the Either type. 
 *)
type esymbol = (sort, sorted_symbol) Either.t

(** Auxiliary state of the E-matching abstract machine. 
 *  Stores the currently active patterns.
 *  Used for per-multi-pattern pruning and filtering. 
 *)
type state = TermSet.t

(** Transition between two consecutive trigger terms in a multi-pattern. 
 *  Used for updating/initializing the auxiliary state.
 *)
type step = (TermSet.t, (term * term) list) Either.t

      
(** E-matching code trees for instantiating templates of some type 'a *)
type 'a ematch_code =
  | Init of step * esymbol * int * 'a ematch_code
  | Bind of int * sorted_symbol * int * 'a ematch_code
  | Check of int * term * 'a ematch_code
  | Compare of int * int * 'a ematch_code
  | Choose of 'a ematch_code list
  | Yield of int IdMap.t * ('a list) TermMap.t * 'a list
  | Prune of int * sorted_symbol * 'a ematch_code
  | Filter of (int IdMap.t * filter list) TermMap.t * 'a ematch_code
  | Backtrack of state * 'a ematch_code
  | ChooseTerm of state * int * 'a ematch_code * CC.Node.t list list

(** Pretty printing of E-matching code trees *)
open Format

let pr_var_binding ppf (x, i) =
  fprintf ppf "%a -> %d" pr_ident x i

let pr_ematch_code pr_inst ppf =
  let pr_step ppf = function
    | Either.First ts -> pr_term_list ppf (TermSet.elements ts)
    | Either.Second tts -> pr_list_comma (fun ppf (t1, t2) -> fprintf ppf "%a -> %a" pr_term t1 pr_term t2) ppf tts
  in
  let rec pr_ematch_code ppf = function
    | Choose cs ->
        fprintf ppf "@<-3>%s@ %a" "choose" pr_choose cs
    | Init (step, sym, i, next) ->
        fprintf ppf "init(@[%a,@ %d@])@\n%a" pr_step step i pr_ematch_code next
    | Bind (i, sym, o, next) ->
        fprintf ppf "bind(@[%d,@ (%a, %d),@ %d@])@\n%a" i pr_sym (fst sym) (List.length (fst @@ snd sym)) o pr_ematch_code next
    | Check (i, t, next) ->
        fprintf ppf "check(@[%d,@ %a@])@\n%a" i pr_term t pr_ematch_code next
    | Compare (i, j, next) ->
        fprintf ppf "compare(@[%d,@ %d@])@\n%a" i j pr_ematch_code next
    | Yield (vs, fs, gs) ->
        let pr_numbered_forms ppf fs =
          (pr_list 0
             (fun ppf _ -> fprintf ppf ",@\n")
             (fun i ppf f -> fprintf ppf "@[<2>%2d:@ @[%a@]@]" i pr_inst f)) ppf fs
        in
        fprintf ppf "@[<2>yield(@[[%a]@]) ->@\n%a@\n%a@]"
          (pr_list_comma pr_var_binding) (IdMap.bindings vs)
          (pr_list 0
             (fun ppf _ -> fprintf ppf ",@\n")
             (fun _ ppf (t, fs) -> fprintf ppf "@[<2>%a:@\n%a@]"
                 pr_term t pr_numbered_forms fs)) (TermMap.bindings fs)
          pr_numbered_forms gs
    | Prune (i, sym, next) ->
        fprintf ppf "prune(@[%d,@ %a@])@\n%a" i pr_sym (fst sym) pr_ematch_code next
    | Filter (filters, next) ->
        fprintf ppf "filter(@[%a@])@\n%a"
          pr_term_list (filters |> TermMap.bindings |> List.map fst)
          (*(pr_list_comma pr_var_binding) (IdMap.bindings vs)
            pr_term t
            pr_filter filters*)
          pr_ematch_code next
    | Backtrack (ts, next) ->
        fprintf ppf "backtrack(@[[%a]@])@\n@%a" pr_term_list (TermSet.elements ts) pr_ematch_code next
    | ChooseTerm (ts, i, next, _) ->
        fprintf ppf "choose_term(@[%d@])@\n%a" i pr_ematch_code next
        
  and pr_choose ppf = function
    | [] -> ()
    | [c] -> fprintf ppf "{@[<1>@\n%a@]@\n}" pr_ematch_code c
    | c :: cs -> fprintf ppf "{@[<1>@\n%a@]@\n}@ @ @<-3>%s@ %a" pr_ematch_code c "or" pr_choose cs
  in pr_ematch_code ppf
          
let print_ematch_code string_of_inst out_ch code =
  print_of_format (pr_ematch_code string_of_inst) code out_ch
        
(** A few utility functions *)

(** Get the continuation of the first command *)
let continuation = function
  | Init (_, _, _, next)
  | Bind (_, _, _, next)
  | Check (_, _, next)
  | Compare (_, _, next)
  | Filter (_, next)
  | Backtrack (_, next) -> next
  | _ -> failwith "illegal argument to continuation"

(** Get the maximum register in code tree c, yields -1 if c uses no registers *)
let max_reg c =
  let rec mr m = function
    | Init (_, _, i, c) 
    | Check (i, _, c)
    | ChooseTerm (_, i, c, _) -> mr (max m i) c
    | Filter (_, c)
    | Prune (_, _, c)
    | Backtrack (_, c) -> mr m c
    | Bind (i, _, j, c)
    | Compare (i, j, c) -> mr (max (max m i) j) c
    | Choose cs ->
        List.fold_left mr m cs
    | Yield (vs, _, _) -> IdMap.fold (fun _ -> max) vs m
  in
  mr (-1) c

(** Make a choice tree out of trees c1 and 
  * Avoids the creation of nested choice nodes. *)
let mk_choose c1 c2 =
  match c1, c2 with
  | Choose cs1, Choose cs2 -> Choose (cs1 @ cs2)
  | Choose cs1, _ -> Choose (cs1 @ [c2])
  | _, Choose cs2 -> Choose (c1 :: cs2)
  | _ -> Choose [c1; c2]

(** Work queue for pattern compilation *)
module WQ = PrioQueue.Make
    (struct
      type t = int
      let compare = compare
    end)
    (struct
      type t = term
      let compare t1 t2 =
        (* Rational for the following definition: 
         * Entries i -> x and i -> t where t is ground should be processed before entries i -> f(t_1, ..., t_n).
         * This is to delay the creation of branching nodes that introduce backtracking points. *)
        if is_ground_term t1 && not @@ is_ground_term t2 then -1
        else match t1, t2 with
        | Var _, App _ -> -1
        | App _, Var _ -> 1
        | _ -> compare t1 t2  
    end)

(** Triggers of multi-patterns. *)
type trigger = term * filter list

(** A multi-pattern for instantiating templates of generic type 'a. *)
type 'a pattern = 'a * trigger list
    
(** Compile the list of multi-patterns [patterns] into an ematching code tree. *)
let compile (patterns: ('a pattern) list): 'a ematch_code =
  (* do some heuristic analysis on the patterns so as to optimize the order 
   * of their triggers to faciliate sharing across patterns in the code tree *)
  (* First count how often each trigger term occurs across all patterns *)
  let occurs =
    List.fold_left
      (fun acc (_, pattern) ->
        List.fold_left 
          (fun acc -> function
            | App _ as t, _ ->
                let curr = TermMap.find_opt t acc |> Opt.get_or_else 0 in
                TermMap.add t (curr + 1) acc
            | _ -> acc)
         acc pattern)
      TermMap.empty
      patterns
  in
  let patterns =
    let compare_triggers (t1, _) (t2, _) =
      let get_count t = 
        TermMap.find_opt t occurs |>
        Opt.get_or_else 0
      in
      (* first prioritize terms that bind more variables as this helps to avoid back-tracking *)
      let c1 =
        - (compare
             (IdSet.cardinal (fv_term t1))
             (IdSet.cardinal (fv_term t2)))
      in
      if c1 = 0 then
        (* next, prioritize terms that occur more often across many patterns *)
        let c2 = compare (get_count t2) (get_count t1) in
        if c2 = 0 then compare t1 t2
        else c2
      else c1
    in
    List.map (fun (tpl, pattern) ->
      (tpl, List.sort compare_triggers pattern))
        patterns
  in
  let esymbol_of = function
    | Var (_, srt) -> Either.first srt
    | t -> Either.second (sorted_symbol_of t |> Opt.get)
  in
  let add_args_to_queue w o args =
    List.fold_left
      (fun (w', o') arg -> WQ.insert o' arg w', o' + 1)
      (w, o) args
  in
  let prune args o next =
    let code, _ =
      List.fold_left
        (fun (next, o) -> function
          | App (sym, _, _) as t when not @@ is_ground_term t ->
              Prune (o, sorted_symbol_of t |> Opt.get, next), o + 1
          | _ -> next, o + 1)
        (next, o) args
    in
    code
  in
  let update_yield_templates t_filters_opt fs gs template =
    match t_filters_opt with
    | Some (t, _) ->
        let t_templates = TermMap.find_opt t fs |> Opt.get_or_else [] in
        TermMap.add t (template :: t_templates) fs, gs
    | None -> fs, template :: gs
  in
  (* Compile a multi-pattern into a code tree.
   * f: info about current term of the multi-pattern that is being processed.
   * pattern: remaining trigger terms of the multi-pattern that still need to be processed.
   * w: work queue of subterms of [f] that still need to be processed.
   * v: accumulated map of variable to register bindings.
   * o: number of next unused register.
   *)
  let rec compile f pattern w v o =
    let rec c w v o =
      if WQ.is_empty w then init f pattern v o else
      let i, t, w' = WQ.extract_min w in
      match t with
      | Var (x, _) when not @@ IdMap.mem x v ->
          c w' (IdMap.add x i v) o
      | Var (x, _) ->
          let next = c w' v o in
          let j = IdMap.find x v in
          if i = j then next
          else Compare (i, j, next)
      | t when is_ground_term t ->
          Check (i, t, c w' v o)
      | App (sym, args, _) ->
          let w'', o' = add_args_to_queue w' o args in
          let next = prune args o (c w'' v o') in
          Bind (i, sorted_symbol_of t |> Opt.get, o, next)
    in
    c w v o
  and init f pattern v o : 'a ematch_code =
    let template, t_filters_opt = f in
    let code =
      match pattern with
      | [] ->
          let fs, gs = update_yield_templates t_filters_opt TermMap.empty [] template in
          Yield (v, fs, gs)
      | (t', filters') :: pattern' ->
          let args = args_of t' in
          let w, o' = add_args_to_queue WQ.empty o args in
          let next = prune args o (compile (template, Some (t', filters')) pattern' w v o') in
          let ts = match t_filters_opt with
          | Some (t, _) -> Either.second [t, t']
          | None -> Either.first @@ TermSet.singleton t'
          in
          Init (ts, esymbol_of t', o, next)
    in
    match t_filters_opt with
    | Some (t, (_ :: _ as fs)) ->
        let filters = TermMap.singleton t (v, fs) in
        Filter (filters, code)
    | _ -> code
  in
  let seq cs fchild =
    let rec s = function
      | Init (ts, sym, o, c) :: cs -> Init (ts, sym, o, s cs)
      | Check (i, t, c) :: cs -> Check (i, t, s cs)
      | Compare (i, j, c) :: cs -> Compare (i, j, s cs)
      | Bind (i, sym, o, c) :: cs -> Bind (i, sym, o, s cs)
      | Prune (i, fs, c) :: cs -> Prune (i, fs, s cs)
      | Filter (filters, c) :: cs -> Filter (filters, s cs)
      | [] -> fchild
      | _ -> assert false
    in
    s (List.rev cs)
  in
  let branch f pattern comps fchild w v o =
    seq comps (mk_choose (compile f pattern w v o) fchild)
  in
  let check_if_queue_processed w v =
    WQ.fold
      (fun i t (v', fully_processed) ->
        match t with
        | App _ -> v', false
        | Var (x, _) ->
            IdMap.add x i v',
            fully_processed && (IdMap.find_opt x v' |> Opt.get_or_else i |> (=) i)
      )
      w (v, true)
  in
  let _print_wq w =
    WQ.fold (fun i t _ -> Printf.printf "%d -> %s, " i (string_of_term t)) w ();
    print_newline ();
  in
  (* Check whether [(f, pattern, w, v)] is compatible with the first node of [code].
   * If yes, return updated values [(code', w', v', f', pattern')]. *)
  let compatible f pattern w v code = 
    match code with
    | Init (ts, sym, o, next) ->
        (* Has w been fully processed? *)
        let v', fully_processed = check_if_queue_processed w v in
        if fully_processed then
          match pattern with
          | (t', filters') :: pattern' when esymbol_of t' = sym ->
              let w', _ = add_args_to_queue WQ.empty o (args_of t') in
              let f' = (fst f, Some (t', filters')) in
              let ts' =
                ts |>
                Either.value_map
                  (fun ts -> TermSet.add t' ts |> Either.first)
                  (fun tts ->
                    snd f |>
                    Opt.map (fun (t, _) ->
                      (t, t') :: tts |> Util.remove_duplicates (=) |> Either.second) |>
                    Opt.get_or_else (TermSet.singleton t' |> Either.first))
              in
              let code' = Init (ts', sym, o, next) in
              Some (code', w', v', f', pattern')
          | _ -> None
        else None
    | Filter (filters, next) ->
        (match f with
        | inst, Some (t, fs) ->
            let v' =
              WQ.fold
                (fun i t v -> match t with
                | Var (x, _) -> IdMap.add x i v
                | _ -> v)
                w IdMap.empty
            in
            let filters'_opt =
              (* Make sure that there is no entry for t in filters, respectively, that the entry is compatible *)
              match TermMap.find_opt t filters with
              | None ->
                  Some (TermMap.add t (v', fs) filters)
              | Some (v'', fs'') when Hashtbl.hash (v'', fs'') = Hashtbl.hash (v', fs) ->
                  Some (TermMap.add t (v', fs) filters)
              | _ -> None
            in
            filters'_opt |> Opt.map (fun filters' -> Filter (filters', next), w, v, (inst, None), pattern)
        | _, None -> None)
    | Check (i, t, _) ->
        (match WQ.find_opt i w with
        | Some t' when t = t' -> Some (code, WQ.delete i w, v, f, pattern)
        | _ -> None)
    | Compare (i, j, _) ->
        let ti_opt = WQ.find_opt i w in
        (match ti_opt with
        | Some (Var (x, _) as ti) ->
            let v'_opt = match WQ.find_opt j w with
            | Some tj when ti = tj -> Some (IdMap.add x j v)
            | None when IdMap.find_opt x v = Some j -> Some v
            | _ -> None
            in
            Opt.map (fun v' -> code, WQ.delete i w, v', f, pattern) v'_opt
        | _ -> None)
    | Bind (i, sym, o, _) ->
        (match WQ.find_opt i w with
        | Some (App (_, args, _) as t) when sorted_symbol_of t = Some sym ->
            let w', _ = add_args_to_queue w o args in
            Some (code, WQ.delete i w', v, f, pattern)
        | _ -> None)
    | _ -> None
  in
  let rec insert_code f pattern w v o comps incomps code: 'a ematch_code * int =
    match code with
    | Choose cs ->
        if incomps = [] then
          let code', score = insert_choose f pattern cs w v o in
          seq comps code', score + List.length comps
        else branch f pattern comps (seq incomps code) w v o, List.length comps
    | Yield (v1, fs, gs) ->
        let v2, fully_processed = check_if_queue_processed w v in
        let v1_union_v2 = IdMap.union (fun x i j -> Some i) v1 v2 in
        let v2_union_v1 = IdMap.union (fun x i j -> Some j) v1 v2 in
        let filters = snd f |> Opt.map snd |> Opt.get_or_else [] in
        if incomps = [] && pattern = [] && fully_processed && filters = [] && IdMap.equal (=) v1_union_v2 v2_union_v1
        then
          let yield =
            let fs', gs' = update_yield_templates (snd f) fs gs (fst f) in
            Yield (v1_union_v2, fs', gs')
          in
          seq comps yield, List.length comps + 1
        else begin
          (*Printf.printf "failed\n";
          print_ematch_code (fun ppf (f, _) -> pr_form ppf f) stdout code;
          print_newline();
          if incomps <> [] then Printf.printf "incomps";
          if pattern <> [] then Printf.printf "pattern";
          if not fully_processed then Printf.printf "processed";
          if filters <> [] then Printf.printf "filters";                    
          print_newline();*)
          branch f pattern comps (seq incomps code) w v o, List.length comps
        end
    | Prune _ ->
        branch f pattern comps (seq incomps code) w v o, List.length comps
    | code ->
        let next = continuation code in
        compatible f pattern w v code |>
        Opt.map (fun (code', w', v', f', pattern') ->
          insert_code f' pattern' w' v' o (code' :: comps) incomps next) |>
        Opt.lazy_get_or_else (fun () ->
          match code with
          | Init _ -> branch f pattern comps (seq incomps code) w v o, List.length comps
          | _ -> insert_code f pattern w v o comps (code :: incomps) next)
  and insert_choose f pattern cs w v o =
    let cs', _, best =
      List.fold_right
        (fun code (cs', cs, best) ->
          match insert_code f pattern w v o [] [] code with
          | code', score when score > best ->
              code' :: cs, code :: cs, score
          | _ -> code :: cs', code :: cs, best
        )
        cs ([], [], 0) 
    in
    if best = 0
    then Choose (compile f pattern w v o :: cs), 0
    else Choose cs', best
  in   
  List.fold_left
    (fun code (f, pattern) ->
      let code', _ = insert_code (f, None) pattern WQ.empty IdMap.empty (max_reg code + 1) [] [] code in
      code'
    )
    (Choose []) patterns
    
(** The E-matching abstract machine.
 *  Runs the given E-matching code tree [code] on the E-graph [ccgraph]. 
 *  Yields a hash table mapping templates of type 'a to the computed variable substitutions. 
 *)
let run (code: 'a ematch_code) ccgraph : ('a, subst_map) Hashtbl.t =
  let egraph = CC.get_egraph ccgraph in
  (* some utility functions for working with the e-graph *)
  let get_apps sym =
    CC.EGraph.fold
      (fun (n, sym') n_apps apps ->
        if sym = sym'
        then CC.NodeListSet.union n_apps apps
        else apps)
      egraph CC.NodeListSet.empty |>
    CC.NodeListSet.elements
  in
  let get_reps srt =
    CC.EGraph.fold
      (fun (n, sym) _ reps ->
        if snd @@ snd sym = srt
        then CC.NodeListSet.add [n] reps
        else reps)
      egraph CC.NodeListSet.empty |>
      CC.NodeListSet.elements
  in
  let get_apps_of_node n sym =
    CC.EGraph.find_opt (n, sym) egraph |>
    Opt.get_or_else CC.NodeListSet.empty |>
    CC.NodeListSet.elements
  in
  (* initialize registers *)
  let regs = Array.make (max_reg code + 1) (CC.rep_of_term ccgraph mk_true_term) in
  (* create result table *)
  let insts = Hashtbl.create 1000 in
  (* the actual machine *)
  let rec run state = function
    | Init (step, esym, o, next) :: stack ->
        let ts = state in
        (*print_endline ("init " ^ (esym |> Either.value_map string_of_sort (fun sym -> string_of_symbol (fst sym))));
        Printf.printf "active terms: ";
        print_list stdout pr_term (TermSet.elements ts);
        print_newline ();*)
        let terms =
          esym |> Either.map get_reps get_apps |> Either.value
        in
        let ts' =
          step |>
          Either.value_map
            (fun ts' -> ts')
            (fun tts ->
              List.fold_left (fun ts' (t, t') ->
                if TermSet.mem t ts then TermSet.add t' ts'
                else ts')
                TermSet.empty tts)
        in
        run ts' (ChooseTerm (ts', o, next, terms) :: stack)
    | Bind (i, sym, o, next) :: stack ->
        (*Printf.printf "bind(%d, %s)\n" i (string_of_symbol @@ fst sym);*)
        let apps = get_apps_of_node (regs.(i)) sym in
        run state (ChooseTerm (state, o, next, apps) :: stack)
    | Check (i, t, next) :: stack ->
        (*Printf.printf "check(%d, %s)\n" i (string_of_term t);*)
        if CC.rep_of_term ccgraph t = regs.(i)
        then run state (next :: stack)
        else begin
          (* let t' = CC.term_of_rep ccgraph regs.(i) in
          Printf.printf "  failed with %d = %s\n" i (string_of_term t');*)
          run state stack
        end
    | Compare (i, j, next) :: stack ->
        (* Printf.printf "compare(%d, %d)\n" i j;*)
        if regs.(i) = regs.(j)
        then run state (next :: stack)
        else begin
          (* let ti = CC.term_of_rep ccgraph regs.(i) in
          let tj = CC.term_of_rep ccgraph regs.(j) in
          Printf.printf "  failed with %d = %s and %d = %s \n" i (string_of_term ti) j (string_of_term tj);*)
          run state stack
        end
    | Choose cs :: stack ->
        run state (List.map (fun c -> Backtrack (state, c)) cs @ stack)
    | Yield (vs, fs, gs) :: stack ->
        let ts = state in
        let sm = IdMap.map (fun i -> CC.term_of_rep ccgraph regs.(i)) vs in
        TermSet.iter (fun t ->
          TermMap.find_opt t fs |>
          Opt.iter (List.iter (fun f -> Hashtbl.add insts f sm))) ts;
        List.iter (fun f -> Hashtbl.add insts f sm) gs;
        run state stack
    | Prune (i, sym, next) :: stack ->
        (* Printf.printf "prune(%d, %s)\n" i (string_of_symbol @@ fst sym);*)
        let n = regs.(i) in
        let funs_n = CC.funs_of_rep ccgraph n in
        if BloomFilter.mem sym funs_n
        then run state (next :: stack)
        else run state stack
    | Filter (filters, next) :: stack ->
        let ts = state in
        let ts' =
          TermSet.filter
            (fun t ->
              let t_filters = TermMap.find_opt t filters in
              match t_filters with
              | Some (vs, fs) ->
                  let sm = IdMap.map (fun i -> CC.term_of_rep ccgraph regs.(i)) vs in
                  InstGen.filter_term fs (subst_term sm t) sm
              | None -> true)
            ts
        in
        if TermSet.is_empty ts'
        then run state stack
        else run ts' (next :: stack)
    | ChooseTerm (state', o, next, args :: apps) :: stack ->
        (* Printf.printf "choosing app: ";*)
        let _ =
          List.fold_left
            (fun i arg ->
              (* Printf.printf "%d -> %s, " i (string_of_term @@ CC.term_of_rep ccgraph arg);*)
              regs.(i) <- arg; i + 1)
            o args
        in
        (*print_newline ();*)
        run state' (next :: ChooseTerm (state', o, next, apps) :: stack)
    | Backtrack (state', next) :: stack -> run state' (next :: stack)
    | ChooseTerm (_, _, _, []) :: stack ->
        run state stack
    | [] -> insts
  in
  run TermSet.empty [code]

    
(** Generate an E-matching code tree from the given set of axioms. *)
let compile_axioms_to_ematch_code ?(force=false) ?(stratify=(!Config.stratify)) axioms :
    (form * _) ematch_code * (form * _) pattern list = 
  (* *)
  let epr_axioms, axioms = 
    List.partition 
      (fun f -> IdSrtSet.is_empty (vars_in_fun_terms f) || not !Config.instantiate && not force) 
      axioms
  in
  (*print_endline "EPR:";
    List.iter print_endline (List.map string_of_form epr_axioms);*)
  (*let _ = print_endline "Candidate axioms for instantiation:" in
    let _ = print_forms stdout axioms in*)
  let generate_pattern f =
    let fvars0 = sorted_free_vars f in
    let fvars = IdSrtSet.inter fvars0 (vars_in_fun_terms f) in
    (* filter out stratified variables *)
    let fvars, strat_vars =
      let merge_map k a b = match (a,b) with
        | (Some a, Some b) -> Some (a @ b)
        | (Some c, None) | (None, Some c) -> Some c
        | (None, None) -> None 
      in
      let rec gen_tpe acc t = match t with
      | App (_, ts, srt) ->
          List.fold_left
            (IdMap.merge merge_map)
            IdMap.empty
            (List.map (gen_tpe (srt :: acc)) ts)
      | Var (id, _) -> IdMap.add id acc IdMap.empty
      in
      let gen_map =
        TermSet.fold
          (fun t acc -> IdMap.merge merge_map (gen_tpe [] t) acc)
          (fun_terms_with_vars f)
          IdMap.empty
      in
        if stratify then
          IdSrtSet.partition
            (fun (id, srt) ->
              try
                let generating = IdMap.find id gen_map in
                  not (List.for_all (TypeStrat.is_stratified srt) generating)
              with Not_found ->
                begin
                  Debug.warn (fun () -> "BUG in stratification: " ^ (string_of_ident id) ^ "\n");
                  true
                end
            )
            fvars
        else fvars, IdSrtSet.empty
    in
    let strat_var_ids = IdSrtSet.fold (fun (id, _) acc -> IdSet.add id acc) strat_vars IdSet.empty in 
    (* collect all terms in which free variables appear below function symbols *)
    let fun_terms, fun_vars, strat_terms = 
      let rec tt (fun_terms, fun_vars, strat_terms) t =
        match t with
        | App (sym, _ :: _, srt) when srt <> Bool ->
            let tvs = fv_term t in
            if IdSet.is_empty tvs then
              fun_terms, fun_vars, strat_terms
            else if IdSet.is_empty (IdSet.inter strat_var_ids tvs)
            then TermSet.add t fun_terms, IdSet.union tvs fun_vars, strat_terms
            else fun_terms, fun_vars, TermSet.add t strat_terms
        | App (_, ts, _) ->
            List.fold_left tt (fun_terms, fun_vars, strat_terms) ts
        | _ -> fun_terms, fun_vars, strat_terms
      in fold_terms tt (TermSet.empty, IdSet.empty, TermSet.empty) f
    in
    let unmatched_vars =
      IdSrtSet.fold (fun (id, _) acc ->
        if IdSet.mem id fun_vars then acc
        else IdSet.add id acc) fvars IdSet.empty
    in
    let fun_terms, fun_vars =
      TermSet.fold (fun t (fun_terms, fun_vars) ->
        let vs = fv_term t in
        if IdSet.is_empty (IdSet.inter unmatched_vars vs)
        then fun_terms, fun_vars
        else TermSet.add t fun_terms, IdSet.union vs fun_vars)
        strat_terms (fun_terms, fun_vars)
    in
    let strat_vars1 =
      IdSrtSet.filter (fun (id, _) -> not (IdSet.mem id fun_vars)) strat_vars
    in
    (* extract patterns separately to obtain auxilary filters *)
    let patterns = extract_patterns f in
    let fun_terms_with_filters =
      TermSet.fold (fun t acc ->
        try (t, List.assoc t patterns) :: acc
        with Not_found -> (t, []) :: acc)
        fun_terms []
    in
    let f = mk_forall (IdSrtSet.elements strat_vars1) f in
    (f, (fvars0, strat_vars1, unmatched_vars, fun_vars, fun_terms_with_filters)), fun_terms_with_filters
  in
  let patterns = [] in
  let patterns =
    List.fold_right
      (fun f patterns -> ((f, (IdSrtSet.empty, IdSrtSet.empty, IdSet.empty, IdSet.empty, [])), []) :: patterns)
      epr_axioms patterns
  in
  let patterns =
    List.fold_right
      (fun f patterns -> generate_pattern f :: patterns) axioms patterns
  in
  compile patterns, patterns
    
(** Instantiate the axioms encoded in patterns [patterns] and code tree [code] for E-graph [ccgraph]. *)
let instantiate_axioms_from_code patterns code ccgraph : form list =
  let print_debug ((f, (fvars, strat_vars, unmatched_vars, fun_vars, fun_terms_with_filters)), subst_maps) =
    print_endline "--------------------";
    print_endline (string_of_form f);
    Printf.printf "all vars: ";
    print_list stdout pr_ident (List.map fst (IdSrtSet.elements fvars));
    print_newline ();
    Printf.printf "strat vars: ";
    print_list stdout pr_ident (List.map fst (IdSrtSet.elements strat_vars));
    print_newline ();
    Printf.printf "unmatched vars: ";
    print_list stdout pr_ident (IdSet.elements unmatched_vars);
    print_newline ();
    Printf.printf "inst vars: ";
    print_list stdout pr_ident (IdSet.elements fun_vars);
    print_newline ();
    Printf.printf "fun terms: ";
    print_list stdout pr_term (List.map fst fun_terms_with_filters);
    print_newline ();
    Printf.printf "# of insts: %d\n" (List.length subst_maps);
    print_endline "subst_maps:";
    List.iter print_subst_map subst_maps;
    print_endline "--------------------";
  in
  let _ =
    if Debug.is_debug 1 then CC.print_classes ccgraph
  in
  let instances = run code ccgraph in
  let get_form (f, _) = f in
  let grouped_instances =
    List.rev_map
      (fun (f, _) ->
        let sms = Hashtbl.find_all instances f in
        (f, sms))
      patterns
  in
  let _ =
    if Debug.is_debug 1 then begin
      grouped_instances |>
      List.rev_map (fun (f, sms) -> (f, List.filter ((<>) IdMap.empty) sms)) |>
      List.iter print_debug
    end
  in
  grouped_instances |>
  List.fold_left
    (fun instances (f_aux, sms) ->
      List.fold_left (fun instances sm ->
        subst sm (get_form f_aux) :: instances)
        instances sms) []

let instantiate_axioms_from_code patterns code ccgraph =
  measure_call "EMatching.instantiate_axioms" (instantiate_axioms_from_code patterns code) ccgraph

let instantiate_axioms ?(force=false) ?(stratify=(!Config.stratify)) axioms ccgraph =
  let code, patterns = compile_axioms_to_ematch_code ~force:force ~stratify:stratify axioms in
  instantiate_axioms_from_code patterns code ccgraph
    
