(* *********************************************************************)
(*                                                                     *)
(*              The Compcert verified compiler                         *)
(*                                                                     *)
(*          Xavier Leroy, INRIA Paris-Rocquencourt                     *)
(*                                                                     *)
(*  Copyright Institut National de Recherche en Informatique et en     *)
(*  Automatique.  All rights reserved.  This file is distributed       *)
(*  under the terms of the INRIA Non-Commercial License Agreement.     *)
(*                                                                     *)
(* *********************************************************************)

(** The whole compiler and its proof of semantic preservation *)

(** Libraries. *)
Require Import String.
Require Import Coqlib.
Require Import Errors.
Require Import AST.
Require Import Smallstep.
(** Languages (syntax and semantics). *)
Require Csyntax.
Require Csem.
Require Cstrategy.
Require Clight.
Require Csharpminor.
Require Cminor.
Require CminorSel.
Require RTL.
Require LTL.
Require Linear.
Require Mach.
Require Asm.
(** Translation passes. *)
Require Initializers.
Require SimplExpr.
Require SimplLocals.
Require Cshmgen.
Require Cminorgen.
Require Selection.
Require RTLgen.
Require Tailcall.
Require Inlining.
Require Renumber.
Require Constprop.
Require CSE.
Require Deadcode.
Require Allocation.
Require Tunneling.
Require Linearize.
Require CleanupLabels.
Require Stacking.
Require Asmgen.
(** Proofs of semantic preservation. *)
Require SimplExprproof.
Require SimplLocalsproof.
Require Cshmgenproof.
Require Cminorgenproof.
Require Selectionproof.
Require RTLgenproof.
Require Tailcallproof.
Require Inliningproof.
Require Renumberproof.
Require Constpropproof.
Require CSEproof.
Require Deadcodeproof.
Require Allocproof.
Require Tunnelingproof.
Require Linearizeproof.
Require CleanupLabelsproof.
Require Stackingproof.
Require Asmgenproof.

(** Pretty-printers (defined in Caml). *)
Parameter print_Clight: Clight.program -> unit.
Parameter print_Cminor: Cminor.program -> unit.
Parameter print_RTL: Z -> RTL.program -> unit.
Parameter print_LTL: LTL.program -> unit.
Parameter print_Mach: Mach.program -> unit.

Open Local Scope string_scope.

(** * Composing the translation passes *)

(** We first define useful monadic composition operators,
    along with funny (but convenient) notations. *)

Definition apply_total (A B: Type) (x: res A) (f: A -> B) : res B :=
  match x with Error msg => Error msg | OK x1 => OK (f x1) end.

Definition apply_partial (A B: Type)
                         (x: res A) (f: A -> res B) : res B :=
  match x with Error msg => Error msg | OK x1 => f x1 end.

Notation "a @@@ b" :=
   (apply_partial _ _ a b) (at level 50, left associativity).
Notation "a @@ b" :=
   (apply_total _ _ a b) (at level 50, left associativity).

Definition print {A: Type} (printer: A -> unit) (prog: A) : A :=
  let unused := printer prog in prog.

Definition time {A B: Type} (name: string) (f: A -> B) : A -> B := f.

(** We define three translation functions for whole programs: one
  starting with a C program, one with a Cminor program, one with an
  RTL program.  The three translations produce Asm programs ready for
  pretty-printing and assembling. *)

Definition transf_rtl_program (f: RTL.program) : res Asm.program :=
   OK f
   @@ print (print_RTL 0)
   @@ time "Tail calls" Tailcall.transf_program
   @@ print (print_RTL 1)
  @@@ time "Inlining" Inlining.transf_program
   @@ print (print_RTL 2)
   @@ time "Renumbering" Renumber.transf_program
   @@ print (print_RTL 3)
   @@ time "Constant propagation" Constprop.transf_program
   @@ print (print_RTL 4)
   @@ time "Renumbering" Renumber.transf_program
   @@ print (print_RTL 5)
  @@@ time "CSE" CSE.transf_program
   @@ print (print_RTL 6)
  @@@ time "Dead code" Deadcode.transf_program
   @@ print (print_RTL 7)
  @@@ time "Register allocation" Allocation.transf_program
   @@ print print_LTL
   @@ time "Branch tunneling" Tunneling.tunnel_program
  @@@ Linearize.transf_program
   @@ time "Label cleanup" CleanupLabels.transf_program
  @@@ time "Mach generation" Stacking.transf_program
   @@ print print_Mach
  @@@ time "Asm generation" Asmgen.transf_program.

Definition transf_cminor_program (p: Cminor.program) : res Asm.program :=
   OK p
   @@ print print_Cminor
  @@@ time "Instruction selection" Selection.sel_program
  @@@ time "RTL generation" RTLgen.transl_program
  @@@ transf_rtl_program.

Definition transf_clight_program (p: Clight.program) : res Asm.program :=
  OK p 
   @@ print print_Clight
  @@@ time "Simplification of locals" SimplLocals.transf_program
  @@@ time "C#minor generation" Cshmgen.transl_program
  @@@ time "Cminor generation" Cminorgen.transl_program
  @@@ transf_cminor_program.

Definition transf_c_program (p: Csyntax.program) : res Asm.program :=
  OK p 
  @@@ time "Clight generation" SimplExpr.transl_program
  @@@ transf_clight_program.

(** Force [Initializers] to be extracted as well. *)

Definition transl_init := Initializers.transl_init.

(** The following lemmas help reason over compositions of passes. *)

Lemma print_identity:
  forall (A: Type) (printer: A -> unit) (prog: A),
  print printer prog = prog.
Proof.
  intros; unfold print. destruct (printer prog); auto. 
Qed.

Lemma compose_print_identity:
  forall (A: Type) (x: res A) (f: A -> unit), 
  x @@ print f = x.
Proof.
  intros. destruct x; simpl. rewrite print_identity. auto. auto. 
Qed.

(** * Semantic preservation *)

(** We prove that the [transf_program] translations preserve semantics
  by constructing the following simulations:
- Forward simulations from [Cstrategy] / [Cminor] / [RTL] to [Asm]
  (composition of the forward simulations for each pass).
- Backward simulations for the same languages
  (derived from the forward simulation, using receptiveness of the source
  language and determinacy of [Asm]).
- Backward simulation from [Csem] to [Asm]
  (composition of two backward simulations).

These results establish the correctness of the whole compiler! *)

Theorem transf_rtl_program_correct:
  forall p tp,
  transf_rtl_program p = OK tp ->
  forward_simulation (RTL.semantics p) (Asm.semantics tp).
Proof.
  intros.
  unfold transf_rtl_program, time in H.
  repeat rewrite compose_print_identity in H.
  simpl in H.
  set (p1 := Tailcall.transf_program p) in *.
  destruct (Inlining.transf_program p1) as [p11|] eqn:?; simpl in H; try discriminate.
  set (p12 := Renumber.transf_program p11) in *.
  set (p2 := Constprop.transf_program p12) in *.
  set (p21 := Renumber.transf_program p2) in *.
  destruct (CSE.transf_program p21) as [p3|] eqn:?; simpl in H; try discriminate.
  destruct (Deadcode.transf_program p3) as [p31|] eqn:?; simpl in H; try discriminate.
  destruct (Allocation.transf_program p31) as [p4|] eqn:?; simpl in H; try discriminate.
  set (p5 := Tunneling.tunnel_program p4) in *.
  destruct (Linearize.transf_program p5) as [p6|] eqn:?; simpl in H; try discriminate.
  set (p7 := CleanupLabels.transf_program p6) in *.
  destruct (Stacking.transf_program p7) as [p8|] eqn:?; simpl in H; try discriminate.
  eapply compose_forward_simulation. apply Tailcallproof.transf_program_correct. 
  eapply compose_forward_simulation. apply Inliningproof.transf_program_correct. eassumption.
  eapply compose_forward_simulation. apply Renumberproof.transf_program_correct. 
  eapply compose_forward_simulation. apply Constpropproof.transf_program_correct. 
  eapply compose_forward_simulation. apply Renumberproof.transf_program_correct. 
  eapply compose_forward_simulation. apply CSEproof.transf_program_correct. eassumption.
  eapply compose_forward_simulation. apply Deadcodeproof.transf_program_correct. eassumption.
  eapply compose_forward_simulation. apply Allocproof.transf_program_correct. eassumption.
  eapply compose_forward_simulation. apply Tunnelingproof.transf_program_correct.
  eapply compose_forward_simulation. apply Linearizeproof.transf_program_correct. eassumption. 
  eapply compose_forward_simulation. apply CleanupLabelsproof.transf_program_correct. 
  eapply compose_forward_simulation. apply Stackingproof.transf_program_correct.
    eexact Asmgenproof.return_address_exists. eassumption.
  apply Asmgenproof.transf_program_correct; eauto.
Qed.

Theorem transf_cminor_program_correct:
  forall p tp,
  transf_cminor_program p = OK tp ->
  forward_simulation (Cminor.semantics p) (Asm.semantics tp).
Proof.
  intros.
  unfold transf_cminor_program, time in H.
  repeat rewrite compose_print_identity in H.
  simpl in H. 
  destruct (Selection.sel_program p) as [p1|] eqn:?; simpl in H; try discriminate.
  destruct (RTLgen.transl_program p1) as [p2|] eqn:?; simpl in H; try discriminate.
  eapply compose_forward_simulation. apply Selectionproof.transf_program_correct. eauto.
  eapply compose_forward_simulation. apply RTLgenproof.transf_program_correct. eassumption.
  exact (transf_rtl_program_correct _ _ H).
Qed.

Theorem transf_clight_program_correct:
  forall p tp,
  transf_clight_program p = OK tp ->
  forward_simulation (Clight.semantics1 p) (Asm.semantics tp).
Proof.
  intros p tp. unfold transf_clight_program, time; simpl.
  rewrite print_identity.
  caseEq (SimplLocals.transf_program p); simpl; try congruence; intros p0 EQ0.
  caseEq (Cshmgen.transl_program p0); simpl; try congruence; intros p1 EQ1.
  caseEq (Cminorgen.transl_program p1); simpl; try congruence; intros p2 EQ2.
  intros EQ3.
  eapply compose_forward_simulation. apply SimplLocalsproof.transf_program_correct. eauto.
  eapply compose_forward_simulation. apply Cshmgenproof.transl_program_correct. eauto.
  eapply compose_forward_simulation. apply Cminorgenproof.transl_program_correct. eauto.
  exact (transf_cminor_program_correct _ _ EQ3). 
Qed.

Theorem transf_cstrategy_program_correct:
  forall p tp,
  transf_c_program p = OK tp ->
  forward_simulation (Cstrategy.semantics p) (Asm.semantics tp).
Proof.
  intros p tp. unfold transf_c_program, time; simpl.
  caseEq (SimplExpr.transl_program p); simpl; try congruence; intros p0 EQ0.
  intros EQ1.
  eapply compose_forward_simulation. apply SimplExprproof.transl_program_correct. eauto.
  exact (transf_clight_program_correct _ _ EQ1).
Qed.
