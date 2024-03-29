open Unix
open Filename
open Str
open Compile
open Printf
open OUnit2
open ExtLib

type ('a, 'b) either =
  | Left of 'a
  | Right of 'b

let either_printer e =
  match e with
    | Left(v) -> sprintf "Error: %s\n" v
    | Right(v) -> v

let parse_string s =
  let sexp = Sexplib.Sexp.of_string s in
  Parser.parse sexp

let parse_file input_file =
  let sexp = Sexplib.Sexp.input_sexp input_file in
  Parser.parse sexp

let compile_file_to_string input_file =
  let input_program = parse_file input_file in
  (compile_to_string input_program);;

let compile_string_to_string s =
  let input_program = parse_string s in
  (compile_to_string input_program);;

let make_tmpfiles name =
  let (null_stdin, _) = pipe() in
  let stdout_name = (temp_file ("stdout_" ^ name) ".out") in
  let stdin_name = (temp_file ("stderr_" ^ name) ".err") in
  (openfile stdout_name [O_RDWR] 0o600, stdout_name,
   openfile stdin_name [O_RDWR] 0o600, stdin_name,
   null_stdin)

(* Read a file into a string *)
let string_of_file file_name =
  let inchan = open_in file_name in
  let buf = Bytes.create (in_channel_length inchan) in
  really_input inchan buf 0 (in_channel_length inchan);
  Bytes.to_string buf

let rec waitpids (pid1: int) (pid2: int) : int * process_status =
  let pid, status = Unix.waitpid ([]) (-1) in
  if pid = pid1 || pid = pid2 then
    (pid, status)
  else
    waitpids pid1 pid2
;;

let run p out args=
  let maybe_asm_string =
    try Right(compile_to_string p)
    with Failure s ->
      Left("Compile error: " ^ s)
  in
  match maybe_asm_string with
  | Left(s) -> Left(s)
  | Right(asm_string) ->
    let outfile = open_out (out ^ ".s") in
    fprintf outfile "%s" asm_string;
    close_out outfile;
    let (bstdout, bstdout_name, bstderr, bstderr_name, bstdin) = make_tmpfiles "build" in
    let (rstdout, rstdout_name, rstderr, rstderr_name, rstdin) = make_tmpfiles "build" in
    let built_pid = Unix.create_process "make" (Array.of_list [""; out ^ ".run"]) bstdin bstdout bstderr in
    let (_, status) = waitpid [] built_pid in

    let try_running = match status with
    | WEXITED 0 ->
      Right(string_of_file rstdout_name)
    | WEXITED _ ->
      Left(sprintf "Finished with error while building %s:\n%s" out
             (string_of_file bstderr_name))
    | WSIGNALED n ->
      Left(sprintf "Signalled with %d while building %s." n out)
    | WSTOPPED n ->
      Left(sprintf "Stopped with signal %d while building %s." n out) in

    let result = match try_running with
    | Left(_) -> try_running
    | Right(msg) ->
      printf "%s" msg;
      let ran_pid = Unix.create_process ("./" ^ out ^ ".run") (Array.of_list (""::args)) rstdin rstdout rstderr in
      let sleep_pid = Unix.create_process "sleep" (Array.of_list (""::"5"::[])) rstdin rstdout rstderr in
      let (finished_pid, status) = waitpids ran_pid sleep_pid in
      if finished_pid = sleep_pid then
        begin
          Unix.kill ran_pid 9;
          Left(sprintf "Test %s timed out" out)
        end
      else
        begin
          Unix.kill sleep_pid 9;
          match status with
          | WEXITED 0 -> Right(string_of_file rstdout_name)
          | WEXITED n -> Left(sprintf "Error %d: %s" n (string_of_file rstderr_name))
          | WSIGNALED n ->
             Left(sprintf "Signalled with %d while running %s." n out)
          | WSTOPPED n ->
             Left(sprintf "Stopped with signal %d while running %s." n out)
        end
    in
    List.iter close [bstdout; bstderr; bstdin; rstdout; rstderr; rstdin];
    List.iter unlink [bstdout_name; bstderr_name; rstdout_name; rstderr_name];
    result

let try_parse prog_str =
  try Right(parse_string prog_str) with
  | Failure s -> Left("Parse error: " ^ s)

let try_compile (e: Expr.expr) =
  try (let _ = compile_to_string e in "Compilation successful.") with
  | Failure s -> ("Compile error: " ^ s)

let test_run program_str outfile expected (args : string list) _ =
  let full_outfile = "output/" ^ outfile in
  let program = parse_string program_str in
  let result = run program full_outfile args in
  assert_equal (Right(expected ^ "\n")) result ~printer:either_printer

let test_err program_str outfile errmsg (args : string list) _ =
  let full_outfile = "output/" ^ outfile in
  let program = try_parse program_str in
  match program with
  | Left(_) as e ->
    assert_equal
      (Left(errmsg))
      e
      ~printer:either_printer
      ~cmp: (fun check result ->
        match check, result with
        | Left(expect_msg), Left(actual_message) ->
          String.exists actual_message expect_msg
        | _ -> false
      )
  | Right(program) ->
    let result = run program full_outfile args in
    assert_equal
      (Left(errmsg))
      result
      ~printer:either_printer
      ~cmp: (fun check result ->
        match check, result with
        | Left(expect_msg), Left(actual_message) ->
          String.exists actual_message expect_msg
        | _ -> false
      )

