(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*            Xavier Leroy, projet Gallium, INRIA Rocquencourt            *)
(*                          Bill O'Farrell, IBM                           *)
(*                                                                        *)
(*   Copyright 2015 Institut National de Recherche en Informatique et     *)
(*     en Automatique.                                                    *)
(*   Copyright 2015 IBM (Bill O'Farrell with help from Tristan Amini).    *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(* Description of the Z Processor *)

open Misc
open Cmm
open Reg
open Arch
open Mach

(* Instruction selection *)

let word_addressed = false

(* Registers available for register allocation *)

(* Integer register map:
    0                   temporary, null register for some operations (volatile)
    1                   temporary (volatile)
    2 - 5               function arguments and results (volatile)
    6                   function arguments and results (preserved by C)
    7 - 9               general purpose, preserved by C
    10                  domain state pointer (preserved by C)
    11                  allocation pointer (preserved by C)
    12                  general purpose  (preserved by C)
    13                  trap pointer (preserved by C)
    14                  return address (volatile)
    15                  stack pointer (preserved by C)
  Floating-point register map:
    0, 2, 4, 6          function arguments and results (volatile)
    1, 3, 5, 7          general purpose (volatile)
    8 - 14              general purpose, preserved by C
    15                  temporary, preserved by C

Note: integer register r12 is used as GOT pointer by some C compilers.
The code generated by OCaml does not need a GOT pointer, using PC-relative
addressing instead for accessing the GOT.  This frees r12 as a
general-purpose register. *)

let int_reg_name =
    [| "%r2"; "%r3"; "%r4"; "%r5"; "%r6"; "%r7"; "%r8"; "%r9"; "%r12" |]

let float_reg_name =
    [| "%f0"; "%f2"; "%f4"; "%f6"; "%f1"; "%f3"; "%f5"; "%f7";
       "%f8"; "%f9"; "%f10"; "%f11"; "%f12"; "%f13"; "%f14"; "%f15" |]

let num_register_classes = 2

let register_class r =
  match r.typ with
  | Val | Int | Addr -> 0
  | Float -> 1

let num_available_registers = [| 9; 15 |]

let first_available_register = [| 0; 100 |]

let register_name r =
  if r < 100 then int_reg_name.(r) else float_reg_name.(r - 100)

let rotate_registers = true

(* Representation of hard registers by pseudo-registers *)

let hard_int_reg =
  let v = Array.make 9 Reg.dummy in
  for i = 0 to 8 do v.(i) <- Reg.at_location Int (Reg i) done; v

let hard_float_reg =
  let v = Array.make 16 Reg.dummy in
  for i = 0 to 15 do v.(i) <- Reg.at_location Float (Reg(100 + i)) done; v

let all_phys_regs =
  Array.append hard_int_reg hard_float_reg

let phys_reg n =
  if n < 100 then hard_int_reg.(n) else hard_float_reg.(n - 100)

let stack_slot slot ty =
  Reg.at_location ty (Stack slot)

let loc_spacetime_node_hole = Reg.dummy  (* Spacetime unsupported *)

(* Calling conventions *)

let calling_conventions
    first_int last_int first_float last_float make_stack stack_ofs arg =
  let loc = Array.make (Array.length arg) Reg.dummy in
  let int = ref first_int in
  let float = ref first_float in
  let ofs = ref stack_ofs in
  for i = 0 to Array.length arg - 1 do
    match arg.(i).typ with
    | Val | Int | Addr as ty ->
        if !int <= last_int then begin
          loc.(i) <- phys_reg !int;
          incr int
        end else begin
          loc.(i) <- stack_slot (make_stack !ofs) ty;
          ofs := !ofs + size_int
        end
    | Float ->
        if !float <= last_float then begin
          loc.(i) <- phys_reg !float;
          incr float
        end else begin
          loc.(i) <- stack_slot (make_stack !ofs) Float;
          ofs := !ofs + size_float
        end
  done;
  (loc, Misc.align !ofs 16)
  (* Keep stack 16-aligned. *)

let incoming ofs = Incoming ofs
let outgoing ofs = Outgoing ofs
let not_supported _ofs = fatal_error "Proc.loc_results: cannot call"

let max_arguments_for_tailcalls = 5

let loc_arguments arg =
  calling_conventions 0 4 100 103 outgoing 0 arg
let loc_parameters arg =
  let (loc, _ofs) = calling_conventions 0 4 100 103 incoming 0 arg in loc
let loc_results res =
  let (loc, _ofs) = calling_conventions 0 4 100 103 not_supported 0 res in loc

(*   C calling conventions under SVR4:
     use GPR 2-6 and FPR 0,2,4,6 just like ML calling conventions.
     Using a float register does not affect the int registers.
     Always reserve 160 bytes at bottom of stack, plus whatever is needed
     to hold the overflow arguments. *)

let loc_external_arguments arg =
  let arg =
    Array.map (fun regs -> assert (Array.length regs = 1); regs.(0)) arg in
  let (loc, ofs) =
    calling_conventions 0 4 100 103 outgoing 160 arg in
  (Array.map (fun reg -> [|reg|]) loc, ofs)

(* Results are in GPR 2 and FPR 0 *)

let loc_external_results res =
  let (loc, _ofs) = calling_conventions 0 0 100 100 not_supported 0 res in loc

(* Exceptions are in GPR 2 *)

let loc_exn_bucket = phys_reg 0

(* See "S/390 ELF Application Binary Interface Supplement"
   (http://refspecs.linuxfoundation.org/ELF/zSeries/lzsabi0_s390/x1542.html)
*)

let int_dwarf_reg_numbers = [| 2; 3; 4; 5; 6; 7; 8; 9; 12; |]

let float_dwarf_reg_numbers =
  [| 16; 17; 18; 19; 20; 21; 22; 23;
     24; 28; 25; 29; 26; 30; 27; 31;
  |]

let dwarf_register_numbers ~reg_class =
  match reg_class with
  | 0 -> int_dwarf_reg_numbers
  | 1 -> float_dwarf_reg_numbers
  | _ -> Misc.fatal_errorf "Bad register class %d" reg_class

let stack_ptr_dwarf_register_number = 15

(* Volatile registers: none *)

let regs_are_volatile _rs = false

(* Registers destroyed by operations *)

let destroyed_at_c_call =
  Array.of_list(List.map phys_reg
    [0; 1; 2; 3; 4;
     100; 101; 102; 103; 104; 105; 106; 107])

let destroyed_at_oper = function
    Iop(Icall_ind _ | Icall_imm _ | Iextcall { alloc = true; _ }) ->
    all_phys_regs
  | Iop(Iextcall { alloc = false; _ }) -> destroyed_at_c_call
  | _ -> [||]

let destroyed_at_raise = all_phys_regs

(* %r14 is destroyed at [Lreloadretaddr], but %r14 is not used for register
   allocation, and thus does not need to (and indeed cannot) occur here. *)
let destroyed_at_reloadretaddr = [| |]

(* Maximal register pressure *)

let safe_register_pressure = function
    Iextcall _ -> 4
  | _ -> 9

let max_register_pressure = function
    Iextcall _ -> [| 4; 7 |]
  | _ -> [| 9; 15 |]

(* Pure operations (without any side effect besides updating their result
   registers). *)

let op_is_pure = function
  | Icall_ind _ | Icall_imm _ | Itailcall_ind _ | Itailcall_imm _
  | Iextcall _ | Istackoffset _ | Istore _ | Ialloc _
  | Iintop(Icheckbound _) | Iintop_imm(Icheckbound _, _) -> false
  | Ispecific(Imultaddf | Imultsubf) -> true
  | _ -> true

(* Layout of the stack *)

let frame_required fd =
  fd.fun_contains_calls
    || fd.fun_num_stack_slots.(0) > 0
    || fd.fun_num_stack_slots.(1) > 0

let prologue_required fd =
  frame_required fd

(* Calling the assembler *)

let assemble_file infile outfile =
  Ccomp.command (Config.asm ^ " " ^
                 (String.concat " " (Misc.debug_prefix_map_flags ())) ^
                 " -o " ^ Filename.quote outfile ^ " " ^ Filename.quote infile)

let init () = ()

let operation_supported = function
  | Cclz _ | Cctz _ | Cpopcnt
  | Cprefetch _
    -> false   (* Not implemented *)
  | Capply _ | Cextcall _ | Cload _ | Calloc | Cstore _
  | Caddi | Csubi | Cmuli | Cmulhi | Cdivi | Cmodi
  | Cand | Cor | Cxor | Clsl | Clsr | Casr
  | Ccmpi _ | Caddv | Cadda | Ccmpa _
  | Cnegf | Cabsf | Caddf | Csubf | Cmulf | Cdivf
  | Cfloatofint | Cintoffloat | Ccmpf _
  | Craise _
  | Ccheckbound
  | Cprobe _ | Cprobe_is_enabled _
    -> true
