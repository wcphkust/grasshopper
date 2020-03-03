(** {5 Symbolic state primitives inspired by Viper's Silicon} *)

open Util
open Grass
open GrassUtil
open Prog
open Printf

exception NotYetImplemented
exception HeapChunkNotFound of string 
let todo () = raise NotYetImplemented
exception SymbExecFail of string
let raise_err str = raise (SymbExecFail str)

 (*
let assert_constr pc_stack v =
  (** TODO add pred_axioms to pc_stack before passing in *)
  if check pc_stack v then None else None
  *) 

(** Symbolic values; grasshopper distinguishes between terms and forms,
  viper's silicon doesn't *)
type symb_val = 
  | Term of term
  | Form of form

let mk_symb_val_term t =
  Term t 

let term_of_symb_val = function
  | Form _ -> None
  | Term t -> Some t 

let mk_fresh_symb_val srt prefix = 
  Term (mk_fresh_var srt prefix)

let string_of_symb_val v =
    match v with
    | Term t -> string_of_term t
    | Form f -> string_of_form f

let equal_symb_vals v1 v2 = 
  match v1, v2 with
  | Term t1, Term t2 -> 
      Debug.debug(fun () -> sprintf "EQUAL SYMBV = Term case (%s) (%s)\n" (string_of_term t1) (string_of_term t2));
      equal (Atom (t1, [])) (Atom (t2, [])) 
  | Form f1, Form f2 -> equal f1 f2
  | _ -> 
      Debug.debug(fun () -> "EQUAL SYMBV = false case\n");
      false

let mk_eq_symbv s t = 
  match s, t with
  | Term ss, Term tt -> mk_eq ss tt
  | _  -> todo()

let symb_val_to_form v = 
  match v with
  | Term t -> todo() 
  | Form f -> f

let rec id_of_symb_val v = 
  match v with
    | Term (Var (id2, _)) -> id2
    | Term (App (_, _, _)) -> failwith "shouldn't get an App as a symb val"
    | Form _ -> failwith "shouldn't get a form in a symb val"

(** Helpers to format prints *)
let lineSep = "\n--------------------\n"

let string_of_pcset s =
  s
  |> List.map (fun ele -> (string_of_symb_val ele))
  |> String.concat ", "

let string_of_symb_val_list vals =
  vals
  |> List.map (fun v -> (string_of_symb_val v))
  |> String.concat ", "
  |> sprintf "[%s]"

let string_of_symb_store s =
  IdMap.bindings s
  |> List.map (fun (k, v) -> (string_of_ident k) ^ ":" ^ (string_of_symb_val v))
  |> String.concat ", "
  |> sprintf "{%s}"

let string_of_symb_val_map store =
  IdMap.bindings store
  |> List.map (fun (k, v) -> (string_of_ident k) ^ ":" ^ (string_of_symb_val v))
  |> String.concat ", "
  |> sprintf "{%s}"

let string_of_symb_fields fields =
  IdMap.bindings fields
  |> List.map (fun (k, v) -> (string_of_ident k) ^ ":" ^ (string_of_symb_val v))
  |> String.concat ", "
  |> sprintf "{%s}"

let string_of_pc_stack pc =
  pc
  |> List.map (fun (pc, bc, vars) ->
      "(" ^ (string_of_ident pc) ^ ", " ^ (string_of_symb_val bc) ^ ", "
      ^ (string_of_pcset vars) ^ ")")
  |> String.concat ", "
  |> sprintf "[%s]"

(** Symbolic store:
  maintains a mapping from grasshopper vars to symbolic vals
  ident -> symb_val . *)
(* Note: adding sort so we can remember type when we sub in symbolic vals *)
type symb_store = symb_val IdMap.t
let empty_store = IdMap.empty

let merge_symb_stores g1 g2 =
  IdMap.merge
  (fun x oy oz -> match oy, oz with
  | Some y, Some z -> 
      failwith "todo: figure out how to merge symb_store variables"
  | Some y, None -> Some y
  | None, Some z -> Some z
  | None, None -> None) g1 g2

let find_symb_val (store: symb_store) (id: ident) =
  Debug.debug(
    fun () ->
      sprintf "trying to find symbv for identifier %s\n"
      (string_of_ident id)
  );
  try IdMap.find id store
  with Not_found ->
    (* this could be a field identifier (e.g., x.next) *)
    failwith ("find_symb_val: Could not find symbolic val for " ^ (string_of_ident id))

(** havoc a list of terms into a symbolic store *)
let mk_fresh_term label srt =
  Term (mk_fresh_var srt label)

let havoc_terms symb_store terms =
  List.fold_left
    (fun sm term ->
      match term with
      | App (_, _, _) -> failwith "tried to havoc a term that isn't a Var"
      | Var (id, srt) -> IdMap.add id (mk_fresh_term "v" srt) sm)
    symb_store terms

(** path condition (pc) stack
  A sequence of scopes a tuple of (scope id, branch condition, [V])
  list[V] is the list of path conditions.
  Note: scope identifiers are used to label branche conditions
    and path conds obtained from two points of program execution.
 *)

(** path condition chunks are of shape (scope id, branch cond, pc list)
 TODO: optimize symb_val list to use a set. *)
type pc_stack = (ident * symb_val * symb_val list) list

let pc_push_new (stack: pc_stack) scope_id br_cond =
  match stack with
  | [] -> [(scope_id, br_cond, [])]
  | stack -> (scope_id, br_cond, []) :: stack

let rec pc_add_path_cond (stack: pc_stack) pc_val =
  match stack with
  | [] -> 
      pc_add_path_cond (pc_push_new stack ("scopeId", 0)
        (mk_fresh_symb_val Bool "brcond")) pc_val 
  | (sid, bc, pcs) :: stack' -> (sid, bc, pc_val :: pcs) :: stack'

let rec pc_after pc_stack scope_id =
  match pc_stack with
  | [] -> []
  | (sid, bc, pcs) :: stack' ->
    if sid = scope_id
    then (sid, bc, pcs) :: pc_after stack' scope_id
    else pc_after stack' scope_id

let pc_collect_constr (stack: pc_stack) =
  List.fold_left
  (fun pclist (id, bc, pcs) -> bc :: (pcs @ pclist))
  [] stack

(* Returns None if the entailment holds, otherwise Some (list of error messages, model) *)
(** carry over from Sid's SymbExec *)
let check_entail prog p1 p2 =
  if p1 = p2 || p2 = mk_true then None
  else (* Dump it to an SMT solver *)
    (** TODO: collect program axioms and add to symbolic state *)
    let p2 = Verifier.annotate_aux_msg "Related location" p2 in
    (* Close the formulas: assuming all free variables are existential *)
    let close f = smk_exists (Grass.IdSrtSet.elements (sorted_free_vars f)) f in
    let labels, f =
      smk_and [p1; mk_not p2] |> close |> nnf
      (* Add definitions of all referenced predicates and functions *)
      |> fun f -> f :: Verifier.pred_axioms prog
      (** TODO: Add axioms *)
      |> (fun fs -> smk_and fs)
      (* Add labels *)
      |> Verifier.add_labels
    in
    let name = fresh_ident "form" |> Grass.string_of_ident in
    Debug.debug (fun () ->
      sprintf "\n\nCalling prover with name %s\n" name);
    match Prover.get_model ~session_name:name f with
    | None -> None
    | Some model -> Some (Verifier.get_err_msg_from_labels model labels, model)

(** SMT solver calls *)
let check pc_stack prog v =
  let constr = pc_collect_constr pc_stack in
  let forms = List.map
    (fun v ->
      match v with
      | Term t ->
          Debug.debug(fun () -> sprintf "check term %s\n"
          (string_of_term t)
          );
          Atom (t, [])
      | Form f -> 
          Debug.debug(fun () -> sprintf "check form %s\n"
          (string_of_form f));
          f)
    constr
  in
  match check_entail prog (smk_and forms) v  with 
  | Some errs -> raise_err "SMT check failed"
  | None -> ()

(** Snapshot defintions *)
type snap =
  | Unit 
  | Snap of symb_val
  | SnapPair of snap * snap 

let snap_pair s1 s2 = SnapPair (s1, s2)

let snap_first s =
  match s with
  | Unit -> Unit
  | Snap s -> Snap s
  | SnapPair (s1, s2) -> s1

let snap_second s =
  match s with
  | Unit -> Unit
  | Snap s -> Snap s
  | SnapPair (s1, s2) -> s2

let rec equal_snaps s1 s2 =
  match s1, s2 with
  | Unit, Unit -> true
  | Unit, Snap ss2 | Snap ss2, Unit -> false
  | SnapPair (l1, r1), SnapPair (l2, r2) ->
      equal_snaps l1 r1 && equal_snaps l2 r2
  | _ -> false

let mk_fresh_snap srt = 
  Snap (Term (mk_fresh_var srt "snap"))

let term_of_snap = function
  | Unit -> Var (("unit", 0), Bool)
  | Snap (Term t) -> t
  | Snap (Form f) -> todo()
  | SnapPair (_, _) -> todo()

(** snapshot adt encoding for SMT solver *)
let snap_adt = (("snap_tree", 0),
  [(("emp", 0), []);
   (("tree", 0),
    [(("fst", 0), FreeSrt ("snap_tree", 0));
     (("snd", 0), FreeSrt ("snap_tree", 0))
    ])
  ])

let snap_typ = Adt (("snap_tree", 0), [snap_adt])

let rec string_of_snap s =
  match s with
  | Unit -> "unit[snap]"
  | Snap ss -> string_of_symb_val ss
  | SnapPair (s1, s2) ->
      sprintf "%s(%s)" (string_of_snap s1) (string_of_snap s2)

(** heap elements and symbolic heap
  The symbolic maintains a multiset of heap chunks which are
  of the form obj(symb_val, snap, [Id -> V]) or a predicate with an id
  and list of args.
  *)
type heap_chunk =
  | Obj of symb_val * snap * symb_val IdMap.t
  | Eps of symb_val * symb_val IdMap.t (* r.f := e *)
  | Pred of ident * snap * symb_val list

let mk_heap_chunk_obj v snp m =
  Obj (v, snp, m)

let equal_field_maps fm1 fm2 =
  IdMap.equal equal_symb_vals fm1 fm2

let equal_symb_val_lst vs1 vs2 =
  List.fold_left2 (fun acc v1 v2 ->
    acc && equal_symb_vals v1 v2)
  true vs1 vs2

let equal_heap_chunks c1 c2 = 
  match c1, c2 with 
  | Obj (v1, s1, sm1), Obj (v2, s2, sm2)
  when v1 = v2 && equal_field_maps sm1 sm2 -> 
    equal_snaps s1 s2
  | Eps (v1, sm1), Eps (v2, sm2) when v1 = v2 -> 
      equal_field_maps sm1 sm2
  | Pred (id1, s1, vs1), Pred (id2, s2, vs2) -> todo()
  | _ -> false

let string_of_hc chunk =
  match chunk with
  | Obj (v, snap, symb_fields) ->
    sprintf "Obj(%s, Snap:%s, Fields:%s)" (string_of_symb_val v)
      (string_of_snap snap) (string_of_symb_fields symb_fields)
  | Eps (v, symb_fields) ->
    sprintf "Eps(%s, Fields: %s)" (string_of_symb_val v) (string_of_symb_fields symb_fields)
  | Pred (id, snap, symb_vals) -> sprintf "Pred(Id:%s, Args:%s, Snap:%s)" (string_of_ident id)
      (string_of_symb_val_list symb_vals) (string_of_snap snap)

type symb_heap = heap_chunk list

let heap_add h stack hchunk = (hchunk :: h, stack)

let rec heap_find_by_val h v = 
  match h with
  | [] -> raise (HeapChunkNotFound (sprintf "for symb_val (%s)" (string_of_symb_val v)))
  | Obj (v1, _, _) as c :: h' ->
      Debug.debug(fun() -> sprintf "heap chunk = (%s) (%s) (%s) (%b)\n" (string_of_hc c) (string_of_symb_val v1) (string_of_symb_val v) (equal_symb_vals v1 v));
      if equal_symb_vals v1 v then 
        c else heap_find_by_val h' v
  | _ -> todo()

let rec heap_find_by_id h id = 
  match h with
  | [] -> raise (HeapChunkNotFound (sprintf "for id(%s)" (string_of_ident id)))
  | Obj (Term (App (_, [ts], _)), _, _) as c :: h' ->
      let target_id =
        match IdSet.find_first_opt (fun e -> true) (free_consts_term ts) with 
         | Some id -> id
         | None -> raise_err "field doesn't have an ident"
      in
      if target_id = id then c else heap_find_by_id h' id 
  | Obj (Term (Var (target_id, _)), _, _) as c :: h' -> 
      if target_id = id then c else heap_find_by_id h' id 
  | _ -> todo()


let heap_find_by_chunk h c = 
  List.find (fun ch -> equal_heap_chunks ch c) h

let rec heap_remove h stack hchunk fc = 
  match h with
  | [] -> raise (HeapChunkNotFound (string_of_hc hchunk))
  | chunk :: h' -> if equal_heap_chunks hchunk chunk then
      match hchunk, chunk with
      | Obj (v1, snp1, _), Obj (v2, snp2, _) ->
        check stack (empty_prog) (mk_eq_symbv v1 v2);
        fc h' snp2
      | Eps (v1, _), Eps (v2, _) ->
        check stack (empty_prog) (mk_eq_symbv v1 v2);
        fc h' Unit
      | Pred (id1, s1, args1), Pred (id2, s2, args2) -> 
        let fs =
          List.map2 (fun f1 f2 -> mk_eq_symbv f1 f2) args1 args2
        in
        check stack (empty_prog) (smk_and fs);
        fc h' Unit
      | _ -> raise_err "heap-remove got unexpected pairs"

let string_of_heap h =
  h
  |> List.map (fun ele -> (string_of_hc ele))
  |> String.concat ", "
  |> sprintf "[%s]"

(** Symbolic State are records that are manipulated during execution:
  1. symbolic store; a mapping from variable names to symbolic values
  2. symbolic heap; records which locations, fields, access predicates are
     accessable along with symbolic values they carry.
  3. path condition stack; this carries all path conditions which are represnented
     as symbolic expressions.
 *)
type symb_state = {
    store: symb_store;
    old_store: symb_store;
    pc: pc_stack;
    heap: symb_heap;
    prog: program; (* need to carry around prog for prover check *)
  }

let mk_symb_state st prog =
  {store=st; old_store=empty_store; pc=[]; heap=[]; prog=prog}

let mk_empty_state = 
  {store=empty_store; old_store=empty_store; pc=[]; heap=[]; prog=empty_prog}

let update_store state store =
  {state with store=store}

let string_of_state s =
  let store = string_of_symb_store s.store in
  let old_store = string_of_symb_store s.old_store in
  let pc = string_of_pc_stack s.pc in
  let heap = string_of_heap s.heap in
  sprintf "\n\tStore: %s,\n\tOld Store: %s\n\tPCStack: %s\n\tHeap: %s" store old_store pc heap
