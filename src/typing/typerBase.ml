open Globals
open Ast
open Type
open Typecore
open Error

type access_mode =
	| MGet
	| MSet
	| MCall

type access_kind =
	| AKNo of string
	| AKExpr of texpr
	| AKSet of texpr * t * tclass_field
	| AKInline of texpr * tclass_field * tfield_access * t
	| AKMacro of texpr * tclass_field
	| AKUsing of texpr * tclass * tclass_field * texpr
	| AKAccess of tabstract * tparams * tclass * texpr * texpr
	| AKFieldSet of texpr * texpr * string * t

type object_decl_kind =
	| ODKWithStructure of tanon
	| ODKWithClass of tclass * tparams
	| ODKPlain

let build_call_ref : (typer -> access_kind -> expr list -> WithType.t -> pos -> texpr) ref = ref (fun _ _ _ _ _ -> assert false)

let relative_path ctx file =
	let slashes path = String.concat "/" (ExtString.String.nsplit path "\\") in
	let fpath = slashes (Path.get_full_path file) in
	let fpath_lower = String.lowercase fpath in
	let flen = String.length fpath_lower in
	let rec loop = function
		| [] -> file
		| path :: l ->
			let spath = String.lowercase (slashes path) in
			let slen = String.length spath in
			if slen > 0 && slen < flen && String.sub fpath_lower 0 slen = spath then String.sub fpath slen (flen - slen) else loop l
	in
	loop ctx.com.Common.class_path

let mk_infos ctx p params =
	let file = if ctx.in_macro then p.pfile else if Common.defined ctx.com Define.AbsolutePath then Path.get_full_path p.pfile else relative_path ctx p.pfile in
	(EObjectDecl (
		(("fileName",null_pos,NoQuotes) , (EConst (String file) , p)) ::
		(("lineNumber",null_pos,NoQuotes) , (EConst (Int (string_of_int (Lexer.get_error_line p))),p)) ::
		(("className",null_pos,NoQuotes) , (EConst (String (s_type_path ctx.curclass.cl_path)),p)) ::
		if ctx.curfield.cf_name = "" then
			params
		else
			(("methodName",null_pos,NoQuotes), (EConst (String ctx.curfield.cf_name),p)) :: params
	) ,p)

let rec is_pos_infos = function
	| TMono r ->
		(match !r with
		| Some t -> is_pos_infos t
		| _ -> false)
	| TLazy f ->
		is_pos_infos (lazy_type f)
	| TType ({ t_path = ["haxe"] , "PosInfos" },[]) ->
		true
	| TType (t,tl) ->
		is_pos_infos (apply_params t.t_params tl t.t_type)
	| TAbstract({a_path=[],"Null"},[t]) ->
		is_pos_infos t
	| _ ->
		false

let get_this ctx p =
	match ctx.curfun with
	| FunStatic ->
		error "Cannot access this from a static function" p
	| FunMemberClassLocal | FunMemberAbstractLocal ->
		let v = match ctx.vthis with
			| None ->
				let v = if ctx.curfun = FunMemberAbstractLocal then
					PMap.find "this" ctx.locals
				else
					add_local ctx VGenerated "`this" ctx.tthis p
				in
				ctx.vthis <- Some v;
				v
			| Some v ->
				ctx.locals <- PMap.add v.v_name v ctx.locals;
				v
		in
		mk (TLocal v) ctx.tthis p
	| FunMemberAbstract ->
		let v = (try PMap.find "this" ctx.locals with Not_found -> assert false) in
		mk (TLocal v) v.v_type p
	| FunConstructor | FunMember ->
		mk (TConst TThis) ctx.tthis p

let rec type_module_type ctx t tparams p =
	match t with
	| TClassDecl {cl_kind = KGenericBuild _} ->
		let _,_,f = InstanceBuilder.build_instance ctx t p in
		let t = f (match tparams with None -> [] | Some tl -> tl) in
		let mt = try
			module_type_of_type t
		with Exit ->
			if follow t == t_dynamic then Typeload.load_type_def ctx p { tpackage = []; tname = "Dynamic"; tparams = []; tsub = None }
			else error "Invalid module type" p
		in
		type_module_type ctx mt None p
	| TClassDecl c ->
		let t_tmp = class_module_type c in
		mk (TTypeExpr (TClassDecl c)) (TType (t_tmp,[])) p
	| TEnumDecl e ->
		let types = (match tparams with None -> List.map (fun _ -> mk_mono()) e.e_params | Some l -> l) in
		mk (TTypeExpr (TEnumDecl e)) (TType (e.e_type,types)) p
	| TTypeDecl s ->
		let t = apply_params s.t_params (List.map (fun _ -> mk_mono()) s.t_params) s.t_type in
		if not (Common.defined ctx.com Define.NoDeprecationWarnings) then
			DeprecationCheck.check_typedef ctx.com s p;
		(match follow t with
		| TEnum (e,params) ->
			type_module_type ctx (TEnumDecl e) (Some params) p
		| TInst (c,params) ->
			type_module_type ctx (TClassDecl c) (Some params) p
		| TAbstract (a,params) ->
			type_module_type ctx (TAbstractDecl a) (Some params) p
		| _ ->
			error (s_type_path s.t_path ^ " is not a value") p)
	| TAbstractDecl { a_impl = Some c } ->
		type_module_type ctx (TClassDecl c) tparams p
	| TAbstractDecl a ->
		if not (Meta.has Meta.RuntimeValue a.a_meta) then error (s_type_path a.a_path ^ " is not a value") p;
		let t_tmp = abstract_module_type a [] in
		mk (TTypeExpr (TAbstractDecl a)) (TType (t_tmp,[])) p

let type_type ctx tpath p =
	type_module_type ctx (Typeload.load_type_def ctx p { tpackage = fst tpath; tname = snd tpath; tparams = []; tsub = None }) None p

let s_access_kind acc =
	let st = s_type (print_context()) in
	let se = s_expr_pretty true "" false st in
	let sfa = s_field_access st in
	match acc with
	| AKNo s -> "AKNo " ^ s
	| AKExpr e -> "AKExpr " ^ (se e)
	| AKSet(e,t,cf) -> Printf.sprintf "AKSet(%s, %s, %s)" (se e) (st t) cf.cf_name
	| AKInline(e,cf,fa,t) -> Printf.sprintf "AKInline(%s, %s, %s, %s)" (se e) cf.cf_name (sfa fa) (st t)
	| AKMacro(e,cf) -> Printf.sprintf "AKMacro(%s, %s)" (se e) cf.cf_name
	| AKUsing(e1,c,cf,e2) -> Printf.sprintf "AKMacro(%s, %s, %s, %s)" (se e1) (s_type_path c.cl_path) cf.cf_name (se e2)
	| AKAccess(a,tl,c,e1,e2) -> Printf.sprintf "AKAccess(%s, [%s], %s, %s, %s)" (s_type_path a.a_path) (String.concat ", " (List.map st tl)) (s_type_path c.cl_path) (se e1) (se e2)
	| AKFieldSet(_) -> ""

let has_constructible_constraint ctx tl el p =
	let ct = (tfun (List.map (fun e -> e.etype) el) ctx.t.tvoid) in
	let rec loop t = match follow t with
		| TAnon a ->
			(try
				unify ctx (PMap.find "new" a.a_fields).cf_type ct p;
				true
			with Not_found ->
					false)
		| TAbstract({a_path = ["haxe"],"Constructible"},_) -> true
		| TInst({cl_kind = KTypeParameter tl},_) -> List.exists loop tl
		| _ -> false
	in
	List.exists loop tl

let unify_static_extension ctx e t p =
	let multitype_involed t1 t2 =
		let check t = match follow t with
			| TAbstract(a,_) when Meta.has Meta.MultiType a.a_meta -> true
			| _ -> false
		in
		check t1 || check t2
	in
	if multitype_involed e.etype t then
		AbstractCast.cast_or_unify_raise ctx t e p
	else begin
		Type.unify e.etype t;
		e
	end