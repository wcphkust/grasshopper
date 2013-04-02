open Form
open Util

(* TODO try to fill in the types of partially typed formula.
 * use some kind of most general unifer (simple backtrack-free version should be enough)
 *)

type my_sort =
  | TBool | TLoc | TInt
  | TSet of my_sort 
  | TFld of my_sort
  | TVar of int
  | TStar of my_sort (* repeated args *)
  | TFun of my_sort list * my_sort

let rec my_sort_to_string t = match t with
  | TBool -> "bool"
  | TLoc -> "loc"
  | TInt -> "Int"
  | TSet s -> "Set("^(my_sort_to_string s)^")"
  | TFld s -> "Fld("^(my_sort_to_string s)^")"
  | TStar s -> (my_sort_to_string s)^"*"
  | TFun (args, ret) -> String.concat " -> " (List.map my_sort_to_string (args @ [ret]))

module TpeMap = Map.Make(struct
    type t = my_sort
    let compare = compare
  end)

module TpeSet = Set.Make(struct
    type t = my_sort
    let compare = compare
  end)

let subst map tpe =
  let sub t =
    try IdMap.find t map with Not_found -> t
  in
  let rec process t = match t with
    | TSet t -> sub (TSet (process t))
    | TFld t -> sub (TFld (process t))
    | TStar t -> sub (TStar (process t))
    | TFun (args, ret) -> sub (TFun (List.map process args, process ret))
    | other -> sub other
  in
    process tpe

let subst_td map tpe =
  let sub t =
    try IdMap.find t map with Not_found -> t
  in
  let rec process t = match sub t with
    | TSet t -> TSet (process t)
    | TFld t -> TFld (process t)
    | TStar t -> TStar (process t)
    | TFun (args, ret) -> TFun (List.map process args, process ret)
    | other -> other
  in
    process tpe

let args_type tpe args = match t with
  | TFun (ts, _) ->
    let rec process t a = match (t, a) with
      | ([TStar tpe], y::ys) -> tpe :: (process t ys)
      | ((TStar tpe)::xs, y::ys) -> failwith "TStar is not the last type of a sequence"
      | (x::xs, y::ys) -> x :: (process xs ys)
      | ([], []) | ([TStar _], []) -> []
      | ([], _) -> failwith "too many arguments"
    in
      process ts args
  | other ->
    assert (args = []);
    []

let return_type tpe = match tpe with
  | TFun (_, r) -> r
  | TStar t -> t
  | other -> other

let rec type_var tpe = match tpe with
  | TVar _ -> TpeSet.singleton tpe
  | TSet t | TFld t | TStar t -> type_var t
  | TFun (args, ret) ->
    List.fold_left
      (fun acc t -> TpeSet.union acc (type_var t))
      (type_var ret)
      args
  | other -> TpeSet.empty

let fresh_param =
  let cnt = ref 0 in
    (fun () ->
      cnt := !cnt + 1;
      TVar !cnt
    )

let fresh_type t =
  let vars = type_var t in
  let map =
    TpeSet.fold
      (fun v acc -> TpeMap.add v (fresh_type ()) acc)
      vars
      TpeMap.empty
  in
    subst map t

let param1 = fresh_param ()
let param2 = fresh_param ()

(* This does not include BoolConst, IntConst, and FreeSym *)
let symbol_types =
  List.fold_left
    (fun acc (k, v) -> SymbolMap.add k v acc)
    SymbolMap.empty
    [(Null, TLoc);
     (Read, TFun ([TFld param1; TLoc], param1));
     (Write, TFun ([TFld param1; TLoc; param1], TFld param1) );
     (EntPnt, TFun ([TFld TLoc; TSet TLoc; TLoc], TLoc));
     (UMinus, TFun ([TInt], TInt) );
     (Plus, TFun ([TStar TInt], TInt));
     (Minus, TFun ([TInt; TInt], TInt) );
     (Mult, TFun ([TStar TInt], TInt));
     (Empty, TSet param1);
     (SetEnum, TFun ([TStar param1], TSet param1));
     (Union, TFun ([TStar (TSet param1)], TSet param1));
     (Inter, TFun ([TStar (TSet param1)], TSet param1));
     (Diff, TFun ([TSet param1; TSet param1], TSet param1));
     (Eq, TFun ([param1; param1], TBool));
     (LtEq, TFun ([TInt; TInt], TBool));
     (GtEq, TFun ([TInt; TInt], TBool));
     (Lt, TFun ([TInt; TInt], TBool));
     (Gt, TFun ([TInt; TInt], TBool));
     (ReachWO, TFun ([TFun TLoc; TLoc; TLoc; TLoc], TBool));
     (Frame, TFun ([TSet TLoc; TSet TLoc; TSet TLoc; TSet TLoc; TFld TLoc; TFld TLoc], TBool));
     (Elem, TFun ([param1; TSet param1], TBool));
     (SubsetEq, ([TSet param1; TSet param1], TBool))
    ]


(* typing equations *)
let equations f =
  let get_type env sym args =
    try (env, IdMap.find sym env)
    with Not_found ->
      begin
        let args_t = List.map (fun _ -> fresh_param ()) args in
        let ret_t = fresh_param () in
        let t = if args <> [] then TFun (args_t, ret_t) else ret_t in
          (IdMap.add sym t env, t)
      end
  in
  let rec deal_with_the_args env tpe args ret_opt =
    let init_eqs = match ret_opt with
      | Some t -> [(return_type tpe, t)]
      | None -> []
    in
    let ats = args_type tpe args in
      List.fold_left2
        (fun (env, eqs) t arg ->
          let (tpe, env, eq) = process_term env arg in
            (env, (t, tpe) :: eq @ eqs)
        )
        (env, init_eqs) 
        ats
        args
  and process_term env t = match t with
    | Var (id, Some (tpe)) -> (tpe, env, [])
    | Var (id, None) -> failwith "the Var should be typed (for the moment)."
    | App (BoolConst b, [], srt_opt) -> (TBool, env, [])
    | App (IntConst i, [], srt_opt) -> (TInt, env, [])
    | App (FreeSym id, ts, srt_opt) ->
      let (env, tpe) = get_type env sym ts in
      let (env, eqs) = deal_with_the_args env tpe ts srt_opt in
        (return_type tpe, env, eqs)
    | App (sym, ts, srt_opt) ->
      let tpe = SymbolMap.find sym symbol_types in
      let (env, eqs) = deal_with_the_args env tpe ts srt_opt in
        (return_type tpe, env, eqs)
  in
  let rec process_form env f = match f with
    | Atom t ->
      let (tpe, env, eqs) = process_term env t in
        (env, (tpe, TBool) :: eqs)
    | BoolOp (_, lst) -> 
      List.fold_left
        (fun (env, acc) f ->
          let (env, eqs) = process_form env f in
            (env, eqs @ acc))
        (env, [])
        lst
    | Binder (_, vars, form, _) ->
       process_form env form
  in
  let (env, eqs) process_form IdMap.empty f in
    (env, eqs)

(* solve the equations using unification *)
let unify eqs =
  let update_subst subst t1 t2 =
    IdMap.add t1 t2 subst
  in
  let process map (t1,t2) = match (subst_td map t1, subst_td map t2) with
    | (x, y) when x = y -> map 
    | (TVar _ as x, y) | (y, TVar _ as x) ->
      assert (not (TpeSet.mem x (type_var y)));
      update_subst map x y
    | (TSet t3, TSet t4) -> process map (t3, t4)
    | (TFld t3, TFld t4) -> process map (t3, t4)
    | (TStar t3, TStar t4) | (TStar t3, t4) | (t4, TStar t3) -> process map (t3, t4)
    | (TFun (a1, r1), TFun (a2, r2)) ->
    | (t1, t2) -> failwith ("ill-typed: " ^ (my_sort_to_string t1) ^ " = " ^ (my_sort_to_string t2) )
  in
  let mgu = List.fold_left process TpeMap.empty eqs in
    mgu

let fill_type env mgu f =
  failwith "TODO"

let typing f =
  let (env, eqs) = equations f in
  let mgu = unify eqs in
    fill_type env mgu f
