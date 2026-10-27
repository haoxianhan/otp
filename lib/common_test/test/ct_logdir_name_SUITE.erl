%%
%% %CopyrightBegin%
%%
%% SPDX-License-Identifier: Apache-2.0
%%
%% Copyright Ericsson AB 2026. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% %CopyrightEnd%
%%

%%%-------------------------------------------------------------------
%%% File: ct_logdir_name_SUITE
%%%
%%% Overlong Common Test job log directories (GitHub issue 7560).
%%%
%%% The logical job name is what indexes, history, events and missing-suite
%%% accounting use. The physical directory component must fit in NAME_MAX
%%% bytes in the native filename encoding, including the ".logs" suffix.
%%% Short names stay byte-for-byte unchanged and do not grow a sidecar.
%%%-------------------------------------------------------------------
-module(ct_logdir_name_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").

-define(name_max, 255).

suite() ->
    [{timetrap, {minutes, 15}}].

all() ->
    [overlong_job_logdir, path_and_atom_names].

init_per_suite(Config) ->
    %% ASCII boundary cases run on any native encoding. The Unicode job is
    %% omitted later when the filesystem cannot store those names.
    Extra = case file:native_name_encoding() of
		utf8 -> [{printable_range, unicode}];
		_ -> []
	    end,
    ct_test_support:init_per_suite(Extra ++ Config).

end_per_suite(Config) ->
    ct_test_support:end_per_suite(Config).

init_per_testcase(TestCase, Config) ->
    ct_test_support:init_per_testcase(TestCase, Config).

end_per_testcase(TestCase, Config) ->
    ct_test_support:end_per_testcase(TestCase, Config).

%% One run covers ct:run_test, the test specification, groups, Unicode,
%% the 255/256 byte boundary, distinct same-prefix names, JUnit links and
%% not_built. A second CLI run repeats into the same directories with the
%% log cache. A third run deletes the cache, plants a legacy directory that
%% has no ct_job_name file, and rebuilds the indexes from disk.
overlong_job_logdir(Config) ->
    Priv = ?config(priv_dir, Config),
    case name_max_probe(Priv) of
	{skip, Reason} ->
	    {skip, Reason};
	ok ->
	    overlong_job_logdir1(Config, Priv)
    end.

overlong_job_logdir1(Config, Priv) ->
    %% priv_dir is per run and stays well under PATH_MAX even with a
    %% 255-byte component. The case under test is that component.
    Src = filename:join(Priv, "src"),
    LogDir = filename:join(Priv, "logs"),
    ok = filelib:ensure_dir(filename:join(LogDir, "x")),
    Jobs = write_jobs(Src, LogDir),
    JunitFile = filename:join(LogDir, "junit_report.xml"),
    Spec = write_spec(Priv, LogDir, Jobs, JunitFile),
    %% false still continues on a slave without an interactive shell.
    %% The default aborts before a log directory is created, which hides
    %% the missing-suite index.
    Opts = [{spec, Spec}, {abort_if_missing_suites, false}],

    %% One deliberate compile failure. Every other job must pass with no skips.
    Expected1 = {passing_jobs(Jobs), 1, {0, 0}},
    Result1 = ct_test_support:run_ct_run_test(Opts, Config),
    ct:pal("ct:run_test => ~p", [Result1]),
    Expected1 = Result1,
    assert_jobs(LogDir, Jobs, 1),
    assert_indexes(LogDir, Jobs),
    assert_junit(JunitFile, Jobs),

    plant_legacy(LogDir),
    plant_read_filter(LogDir),
    %% Exit 1 is "test cases failed" (the uncompilable suite). Exit 2 would
    %% be an aborted run.
    1 = ct_test_support:run_ct_script_start(Opts, Config),
    %% close/1 writes the cache captured at start. The first run therefore
    %% leaves tests = []. The second run's start scans the directories
    %% from the first run, and that is what gets written back.
    assert_cache_keys(LogDir, Jobs),
    assert_jobs(LogDir, Jobs, 2),
    assert_indexes(LogDir, Jobs),
    assert_legacy(LogDir),

    Cache = filename:join(LogDir, "ct_log_cache"),
    ok = file:delete(Cache),
    false = filelib:is_file(Cache),
    ShortSpec = write_short_spec(Priv, LogDir, Jobs),
    Result3 = ct_test_support:run_ct_run_test([{spec, ShortSpec}], Config),
    ct:pal("cache rebuild => ~p", [Result3]),
    {1, 0, {0, 0}} = Result3,
    assert_copies(LogDir, Jobs, 3),
    assert_indexes(LogDir, Jobs),
    assert_legacy(LogDir),
    ok.

%% add_spec/1 passes a path as the job name. add_case/3 can pass an atom.
%% The log directory stays beside the leaf, and a short leaf keeps the
%% historical basename with no sidecar.
%% The suite already owns test_server_ctrl on the CT node, and that node
%% has TEST_SERVER_FRAMEWORK set. A nested add_spec there dies in
%% init_tester. These calls need a fresh node with the patched beams.
path_and_atom_names(Config) ->
    Priv = ?config(priv_dir, Config),
    {file, Ctrl} = code:is_loaded(test_server_ctrl),
    {ok, Peer, Node} = peer:start_link(#{name => ct7560path,
                                         args => code_path_args(),
                                         env => [{"TEST_SERVER_FRAMEWORK",
                                                  "undefined"},
                                                 {"TEST_SERVER_FRAMEWORK_NAME",
                                                  "undefined"}]}),
    try
        PeerCtrl = rpc:call(Node, code, which, [test_server_ctrl]),
        PeerSrv = rpc:call(Node, code, which, [test_server]),
        ct:pal("PEER_WHICH ctrl=~ts server=~ts", [PeerCtrl, PeerSrv]),
        %% The peer must run the same test_server_ctrl beam this suite
        %% loaded. A later -pa of the installed ebin would shadow it.
        Ctrl = PeerCtrl,
        ok = rpc:call(Node, ?MODULE, run_path_and_atom, [Priv])
    after
        peer:stop(Peer)
    end.

code_path_args() ->
    %% -pa prepends, so the last directory is searched first. The beams
    %% this node already loaded must stay in front of any other common_test
    %% ebin (the installed one still contains test_server_ctrl).
    Patched = lists:usort([loaded_dir(M) ||
                              M <- [test_server_ctrl, ct_util,
                                    ct_logs, ct_framework]]),
    Needed = [loaded_dir(test_server), loaded_dir(?MODULE)],
    Front = [Dir || Dir <- Needed, not lists:member(Dir, Patched)],
    lists:append([["-pa", Dir] || Dir <- Front ++ Patched]).

loaded_dir(Mod) ->
    {file, Beam} = code:is_loaded(Mod),
    filename:dirname(Beam).

run_path_and_atom(Priv) ->
    Suite = "-module(path_SUITE).\n"
	    "-export([all/1, t/1]).\n"
	    "all(suite) -> [t].\n"
	    "t(Config) when is_list(Config) -> ok.\n",
    long_spec(Priv, Suite),
    short_spec(Priv, Suite),
    atom_case(Priv, Suite),
    ok.

long_spec(Priv, Suite) ->
    Root = filename:join(Priv, "longspec"),
    Leaf = filename:join([Root, lists:duplicate(70, $a),
			  lists:duplicate(70, $b), lists:duplicate(70, $c)]),
    run_spec(Leaf, Suite),
    Demo = filename:join(Leaf, "demo.logs"),
    true = filelib:is_dir(Demo),
    false = filelib:is_file(filename:join(Demo, "ct_job_name")),
    [] = filelib:wildcard(filename:join(filename:dirname(Leaf), "*.logs")),
    assert_leaf_links(Demo, "demo.logs").

short_spec(Priv, Suite) ->
    Leaf = filename:join([Priv, "shortspec", "s"]),
    run_spec(Leaf, Suite),
    Demo = filename:join(Leaf, "demo.logs"),
    true = filelib:is_dir(Demo),
    false = filelib:is_file(filename:join(Demo, "ct_job_name")),
    assert_leaf_links(Demo, "demo.logs").

atom_case(Priv, Suite) ->
    Dir = filename:join(Priv, "atomjob"),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    ok = file:write_file(filename:join(Dir, "path_SUITE.erl"), Suite),
    {ok, path_SUITE} = compile:file(filename:join(Dir, "path_SUITE.erl"),
				    [{outdir, Dir}]),
    true = code:add_patha(Dir),
    {ok, Cwd} = file:get_cwd(),
    ok = file:set_cwd(Dir),
    {ok, _} = test_server_ctrl:start(),
    ok = test_server_ctrl:add_case(leaf_job, path_SUITE, t),
    test_server_ctrl:wait_finish(),
    ok = file:set_cwd(Cwd),
    Logs = filename:join(Dir, "leaf_job.logs"),
    true = filelib:is_dir(Logs),
    false = filelib:is_file(filename:join(Logs, "ct_job_name")),
    assert_leaf_links(Logs, "leaf_job.logs").

run_spec(Leaf, Suite) ->
    ok = filelib:ensure_dir(filename:join(Leaf, "x")),
    ok = file:write_file(filename:join(Leaf, "path_SUITE.erl"), Suite),
    {ok, path_SUITE} = compile:file(filename:join(Leaf, "path_SUITE.erl"),
				    [{outdir, Leaf}]),
    true = code:add_patha(Leaf),
    Spec = filename:join(Leaf, "demo.spec"),
    ok = file:write_file(Spec, "{topcase, {path_SUITE, all}}.\n"),
    {ok, Cwd} = file:get_cwd(),
    ok = file:set_cwd(Leaf),
    {ok, _} = test_server_ctrl:start(),
    ok = test_server_ctrl:add_spec(Spec),
    test_server_ctrl:wait_finish(),
    ok = file:set_cwd(Cwd).

%% last_link.html lives in the job directory. last_test.html is written
%% with filename:absname/1, so it follows the job's cwd: the parent of
%% that directory. Both show the historical basename.
assert_leaf_links(LogDir, Text) ->
    Text = html_link_text(filename:join(LogDir, "last_link.html")),
    Text = html_link_text(filename:join(filename:dirname(LogDir),
					"last_test.html")).

html_link_text(File) ->
    {ok, Bin} = file:read_file(File),
    {match, [Text]} = re:run(Bin, "<a href=[^>]*>([^<]*)</a>",
			     [{capture, [1], list}]),
    Text.

%%%-----------------------------------------------------------------
%%% Fixtures
%%%-----------------------------------------------------------------

write_jobs(Root, LogDir) ->
    Short = job(Root, short, "s", "t", short_SUITE, undefined, ok, undefined, LogDir),
    B255 = fixed_job(Root, b255, "b255", a255_SUITE, g, ok, ?name_max, LogDir),
    B256 = fixed_job(Root, b256, "b256", a256_SUITE, g, ok, ?name_max + 1, LogDir),
    %% "unic." is 5 bytes, so the 217-byte prefix ends inside a 3-byte
    %% character. "uni." (4 bytes) would have landed on a boundary.
    Uni = case file:native_name_encoding() of
	      utf8 -> [unicode_job(Root, uni, "unic", uni_SUITE, g, ok, LogDir)];
	      _ -> []
	  end,
    P1 = fixed_job(Root, p1, "pfx", p1_SUITE, g, ok, ?name_max + 40, $a, LogDir),
    P2 = fixed_job(Root, p2, "pfx", p2_SUITE, g, tc, ?name_max + 40, $b, LogDir),
    true = maps:get(dir, P1) =/= maps:get(dir, P2),
    Bad = fixed_suite_job(Root, bad, "bad", bad_SUITE, ?name_max + 1, LogDir),
    [Short, B255, B256, P1, P2, Bad | Uni].

job(Root, Id, Parent, Child, Mod, Group, Case, Target, LogDir) ->
    Logical = logical(Parent, Child, Mod, Group, Case),
    Dir = filename:join([Root, Parent, Child]),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    File = filename:join(Dir, atom_to_list(Mod) ++ ".erl"),
    Live = live_check(Id, Target, LogDir, Logical),
    ok = file:write_file(File, suite_src(Mod, Group, Case, Id =/= bad, Live)),
    #{id => Id, dir => Dir, mod => Mod, group => Group, tc => Case,
      logical => Logical, target => Target,
      component => Logical ++ ".logs"}.

%% The case runs after start_log_file has reported loginfo and before the
%% run's final index rebuild. Only the first run can fail this: a later
%% run already has the logical name in the previous index.
live_check(bad, _, _, _) ->
    none;
live_check(_, Target, _, _) when Target =:= undefined; Target =:= ?name_max ->
    none;
live_check(_, _, LogDir, Logical) ->
    {LogDir, Logical}.

fixed_job(Root, Id, Tag, Mod, Group, Case, Target, LogDir) ->
    fixed_job(Root, Id, Tag, Mod, Group, Case, Target, $a, LogDir).

fixed_job(Root, Id, Tag, Mod, Group, Case, Target, Last, LogDir) ->
    Suffix = job_tail(Mod, Group, Case) ++ ".logs",
    {Parent, Child0} = split_pad(Tag, nbytes(Suffix), Target),
    Child = lists:droplast(Child0) ++ [Last],
    Job = job(Root, Id, Parent, Child, Mod, Group, Case, Target, LogDir),
    Target = nbytes(maps:get(component, Job)),
    true = nbytes(Parent) =< ?name_max,
    true = nbytes(Child) =< ?name_max,
    Job.

%% Keep every source-directory component inside NAME_MAX. The overflow is
%% only in the job name, which joins the two basenames with a dot.
split_pad(Tag, SuffixBytes, Target) ->
    Extra = Target - nbytes(Tag) - 1 - SuffixBytes,
    true = Extra >= 0,
    ChildLen = min(?name_max, Extra),
    ParentExtra = Extra - ChildLen,
    true = nbytes(Tag) + ParentExtra =< ?name_max,
    {Tag ++ lists:duplicate(ParentExtra, $p),
     lists:duplicate(ChildLen, $a)}.

fixed_suite_job(Root, Id, Parent, Mod, Target, LogDir) ->
    fixed_job(Root, Id, Parent, Mod, undefined, all, Target, LogDir).

unicode_job(Root, Id, Parent, Mod, Group, Case, LogDir) ->
    Suffix = job_tail(Mod, Group, Case) ++ ".logs",
    Prefix = Parent ++ ".",
    %% Two codepoints past the byte budget. Each is 3 UTF-8 bytes and 1 char.
    N = ((?name_max - nbytes(Prefix) - nbytes(Suffix)) div 3) + 2,
    true = N > 0,
    Child = lists:duplicate(N, 16#6587),
    Job = job(Root, Id, Parent, Child, Mod, Group, Case, overlong, LogDir),
    Comp = maps:get(component, Job),
    true = nbytes(Comp) > ?name_max,
    true = length(Comp) < ?name_max,
    Job.

logical(Parent, Child, Mod, undefined, all) ->
    Parent ++ "." ++ Child ++ "." ++ atom_to_list(Mod);
logical(Parent, Child, Mod, undefined, Case) ->
    Parent ++ "." ++ Child ++ "." ++ atom_to_list(Mod) ++ "." ++
	atom_to_list(Case);
logical(Parent, Child, Mod, Group, Case) ->
    Parent ++ "." ++ Child ++ "." ++ atom_to_list(Mod) ++ "." ++
	atom_to_list(Group) ++ "." ++ atom_to_list(Case).

job_tail(Mod, undefined, all) ->
    "." ++ atom_to_list(Mod);
job_tail(Mod, undefined, Case) ->
    "." ++ atom_to_list(Mod) ++ "." ++ atom_to_list(Case);
job_tail(Mod, Group, Case) ->
    "." ++ atom_to_list(Mod) ++ "." ++ atom_to_list(Group) ++ "." ++
	atom_to_list(Case).

suite_src(Mod, Group, Case, true, Live) ->
    Exports = case Group of
		  undefined ->
		      ["-export([all/0, ", atom_to_list(Case), "/1]).\n",
		       "all() -> [", atom_to_list(Case), "].\n"];
		  _ ->
		      ["-export([all/0, groups/0, init_per_group/2, ",
		       "end_per_group/2, ", atom_to_list(Case), "/1]).\n",
		       "all() -> [{group, ", atom_to_list(Group), "}].\n",
		       "groups() -> [{", atom_to_list(Group), ", [], [",
		       atom_to_list(Case), "]}].\n",
		       "init_per_group(_G, Config) -> [{started, true} | Config].\n",
		       "end_per_group(_G, Config) ->\n",
		       "    true = proplists:get_value(started, Config),\n",
		       "    ok.\n"]
	      end,
    ["-module(", atom_to_list(Mod), ").\n", Exports,
     atom_to_list(Case), "(_Config) ->\n", live_body(Live), "ok.\n"];
suite_src(bad_SUITE, undefined, all, false, _Live) ->
    "-module(bad_SUITE).\n"
    "-export([all/0, ok/0]).\n"
    "all() -> [ok.\n"
    "ok() -> ok.\n".

live_body(none) ->
    "";
live_body({LogDir, Logical}) ->
    Index = filename:join(LogDir, "index.html"),
    Needle = ">" ++ Logical ++ "</a>",
    io_lib:format("    {ok, Bin} = file:read_file(~w),\n"
		  "    Html = unicode:characters_to_list(Bin),\n"
		  "    nomatch =/= string:find(Html, ~w) orelse error(live_index_missing),\n",
		  [Index, Needle]).

write_spec(Priv, LogDir, Jobs, JunitFile) ->
    Terms = [{logdir, LogDir},
	     {abort_if_missing_suites, false},
	     {label, "logdir_name"},
	     {ct_hooks, [{cth_surefire, [{path, JunitFile}]}]} |
	     [spec_term(J) || J <- Jobs]],
    ct_test_support:write_testspec(Terms, Priv, "logdir_name.spec").

write_short_spec(Priv, LogDir, Jobs) ->
    Short = job_by(short, Jobs),
    Terms = [{logdir, LogDir},
	     {label, "logdir_rebuild"},
	     spec_term(Short)],
    ct_test_support:write_testspec(Terms, Priv, "logdir_rebuild.spec").

spec_term(#{id := bad, dir := Dir, mod := Mod}) ->
    {suites, Dir, Mod};
spec_term(#{group := undefined, dir := Dir, mod := Mod, tc := Case}) ->
    {cases, Dir, Mod, [Case]};
spec_term(#{dir := Dir, mod := Mod, group := Group, tc := Case}) ->
    {groups, Dir, Mod, [Group], {cases, [Case]}}.

plant_legacy(LogDir) ->
    Run = filename:join([LogDir,
			 "ct_run.legacy@host.2000-01-01_00.00.01",
			 "legacy_ok.logs",
			 "run.2000-01-01_00.00.01"]),
    ok = filelib:ensure_dir(filename:join(Run, "x")),
    ok = file:write_file(filename:join(Run, "suite.log"),
			 "=successful 1\n=failed 0\n=user_skipped 0\n"
			 "=auto_skipped 0\n"),
    ok = file:write_file(filename:join(Run, "suite.log.html"),
			 "<html><body>legacy</body></html>"),
    CtRun = filename:dirname(filename:dirname(Run)),
    ok = file:write_file(filename:join(CtRun, "index.html"),
			 "<html><body>legacy index</body></html>"),
    Totals = term_to_binary({"legacy@host", "-",
			     ["legacy_ok.logs"],
			     {1, 0, 0, 0, 0}}),
    ok = file:write_file(filename:join(CtRun, "totals.info"), Totals),
    false = filelib:is_file(filename:join(filename:dirname(Run), "ct_job_name")).

%% ordinary.logs has a sidecar that must be ignored. The "~" + 32 hex
%% directory must be read, so its index identity is the sidecar text.
plant_read_filter(LogDir) ->
    CtRun = filename:join(LogDir, "ct_run.decoy@host.2000-01-01_00.00.02"),
    plant_one(CtRun, "ordinary.logs", "not-the-name"),
    Hex = lists:duplicate(32, $a),
    plant_one(CtRun, "z~" ++ Hex ++ ".logs", "hashed-logical"),
    ok = file:write_file(filename:join(CtRun, "index.html"),
			 "<html><body>decoy</body></html>"),
    Totals = term_to_binary({"decoy@host", "-",
			     ["ordinary.logs", "z~" ++ Hex ++ ".logs"],
			     {2, 0, 0, 0, 0}}),
    ok = file:write_file(filename:join(CtRun, "totals.info"), Totals).

plant_one(CtRun, DirName, Sidecar) ->
    Run = filename:join([CtRun, DirName, "run.2000-01-01_00.00.02"]),
    ok = filelib:ensure_dir(filename:join(Run, "x")),
    ok = file:write_file(filename:join(Run, "suite.log"),
			 "=successful 1\n=failed 0\n=user_skipped 0\n"
			 "=auto_skipped 0\n"),
    ok = file:write_file(filename:join(Run, "suite.log.html"),
			 "<html><body>decoy</body></html>"),
    ok = file:write_file(filename:join([CtRun, DirName, "ct_job_name"]), Sidecar).

%%%-----------------------------------------------------------------
%%% Assertions
%%%-----------------------------------------------------------------

name_max_probe(Priv) ->
    Probe = filename:join(Priv, "name-max"),
    ok = file:make_dir(Probe),
    N255 = lists:duplicate(?name_max, $n),
    N256 = lists:duplicate(?name_max + 1, $n),
    case {file:make_dir(filename:join(Probe, N255)),
	  file:make_dir(filename:join(Probe, N256))} of
	{ok, {error, enametoolong}} ->
	    ok;
	Other ->
	    {skip, {name_max, Other}}
    end.

passing_jobs(Jobs) ->
    length([Id || #{id := Id} <- Jobs, Id =/= bad]).

assert_jobs(LogDir, Jobs, Copies) ->
    Found = found_cached(LogDir),
    lists:foreach(fun(Job) -> assert_job(LogDir, Job, Found, Copies) end, Jobs).

%% The third invocation reruns only the short suite, so that job has one
%% more ct_run directory than the others.
assert_copies(LogDir, Jobs, ShortCopies) ->
    Found = found_cached(LogDir),
    lists:foreach(fun(Job = #{id := short}) ->
			  assert_job(LogDir, Job, Found, ShortCopies);
		     (Job) ->
			  assert_job(LogDir, Job, Found, ShortCopies - 1)
		  end, Jobs).

found_cached(LogDir) ->
    Found = found_jobs(LogDir),
    ct:pal("job dirs ~p", [[{filename:basename(filename:dirname(D)), Name}
			    || {D, Name} <- Found]]),
    Found.

assert_job(LogDir, Job = #{logical := Logical}, Found, Copies) ->
    Dirs = [Dir || {Dir, Name} <- Found, Name =:= Logical],
    Copies = length(Dirs),
    Bases = [filename:basename(D) || D <- Dirs],
    true = lists:all(fun(Base) -> Base =:= hd(Bases) end, Bases),
    lists:foreach(fun(Dir) -> assert_one_dir(Job, Dir) end, Dirs),
    case maps:get(id, Job) of
	bad ->
	    Html = read_text(filename:join(LogDir, "index.html")),
	    Row = row_containing(Html, Logical),
	    match = re:run(Row, ">[1-9][0-9]*</a>", [{capture, none}]);
	_ ->
	    ok
    end.

assert_one_dir(#{id := bad, logical := Logical, component := Comp}, Dir) ->
    assert_shortened(Dir, Logical, Comp),
    assert_run_shape(Dir),
    assert_suite_log(Dir, bad);
assert_one_dir(#{id := Id, logical := Logical, component := Comp,
		 target := Target, mod := Mod}, Dir) ->
    case Target of
	undefined ->
	    assert_unchanged(Dir, Logical, Comp);
	?name_max ->
	    assert_unchanged(Dir, Logical, Comp),
	    ?name_max = nbytes(Comp);
	_ ->
	    assert_shortened(Dir, Logical, Comp)
    end,
    assert_run_shape(Dir),
    [Run | _] = run_dirs(Dir),
    assert_suite_log(Dir, Id),
    SuiteHtml = read_text(filename:join(Run, "suite.log.html")),
    true = nomatch =/= string:find(SuiteHtml, Logical),
    case Id of
	short ->
	    ok;
	_ ->
	    ModS = string:lowercase(atom_to_list(Mod)),
	    true = filelib:is_file(filename:join(Run,
						 ModS ++ ".init_per_group.html")),
	    true = filelib:is_file(filename:join(Run,
						 ModS ++ ".end_per_group.html"))
    end.

assert_unchanged(Dir, Logical, Comp) ->
    Comp = filename:basename(Dir),
    Logical = filename:basename(Dir, ".logs"),
    false = filelib:is_file(filename:join(Dir, "ct_job_name")),
    true = nbytes(filename:basename(Dir)) =< ?name_max.

assert_shortened(Dir, Logical, Comp) ->
    Base = filename:basename(Dir),
    true = Base =/= Comp,
    true = nbytes(Base) =< ?name_max,
    true = nbytes(Comp) > ?name_max,
    Logical = read_sidecar(Dir),
    assert_unicode_filename(Base),
    false = filelib:is_dir(filename:join(filename:dirname(Dir), Comp)).

assert_unicode_filename(Name) ->
    Bin = unicode:characters_to_binary(Name, unicode, utf8),
    true = is_binary(Bin),
    Name = unicode:characters_to_list(Bin, utf8).

assert_run_shape(Dir) ->
    Runs = run_dirs(Dir),
    true = Runs =/= [],
    true = filelib:is_file(filename:join(hd(Runs), "suite.log.html")).

assert_suite_log(Dir, bad) ->
    lists:foreach(fun(Run) ->
			  Log = read_text(filename:join(Run, "suite.log")),
			  true = nomatch =/= string:find(Log, "cannot be compiled or loaded"),
			  true = nomatch =/= string:find(Log, "TEST COMPLETE, 0 ok, 0 failed of 0 test cases")
		  end, run_dirs(Dir));
assert_suite_log(Dir, _Id) ->
    lists:foreach(fun(Run) ->
			  Log = read_text(filename:join(Run, "suite.log")),
			  true = nomatch =/= string:find(Log, "TEST COMPLETE, 1 ok, 0 failed of 1 test cases"),
			  true = nomatch =/= string:find(Log, "=auto_skipped  0"),
			  true = nomatch =/= string:find(Log, "=user_skipped  0")
		  end, run_dirs(Dir)).

assert_indexes(LogDir, Jobs) ->
    Top = filename:join(LogDir, "index.html"),
    AllRuns = filename:join(LogDir, "all_runs.html"),
    true = filelib:is_file(Top),
    true = filelib:is_file(AllRuns),
    TopHtml = read_text(Top),
    AllHtml = read_text(AllRuns),
    Found = found_jobs(LogDir),
    %% Comp is defined as Logical ++ ".logs", so basename(Comp, ".logs")
    %% cannot show a shortened directory. Use the directory that was created.
    Shortened = [filename:basename(Dir, ".logs")
		 || {Dir, Name} <- Found, filename:basename(Dir, ".logs") =/= Name],
    true = Shortened =/= [],
    assert_index_names(TopHtml, Found),
    nomatch = string:find(TopHtml, ">not-the-name</a>"),
    lists:foreach(fun(#{logical := Logical}) ->
			  true = nomatch =/= string:find(AllHtml, Logical)
		  end, Jobs),
    assert_hrefs(Top, "suite.log"),
    assert_hrefs(AllRuns, "index.html"),
    RealRuns = [CtRun || CtRun <- filelib:wildcard(filename:join(LogDir, "ct_run.*")),
			 not planted_run(filename:basename(CtRun))],
    lists:foreach(fun(CtRun) ->
			  Index = filename:join(CtRun, "index.html"),
			  true = filelib:is_file(Index),
			  Here = [{D, read_logical(D)}
				  || D <- filelib:wildcard(filename:join(CtRun, "*.logs"))],
			  assert_index_names(read_text(Index), Here),
			  assert_hrefs(Index, "suite.log")
		  end, RealRuns).

%% Link text is the logical name. A shortened directory basename must not
%% be used as that text; the href still points at the real directory.
assert_index_names(Html, Found) ->
    lists:foreach(fun({Dir, Logical}) ->
			  Phys = filename:basename(Dir, ".logs"),
			  true = nomatch =/= string:find(Html, ">" ++ Logical ++ "</a>"),
			  case Phys =:= Logical of
			      true ->
				  ok;
			      false ->
				  nomatch = string:find(Html, ">" ++ Phys ++ "</a>")
			  end
		  end, Found).

assert_hrefs(Index, Needle) ->
    {ok, Bin} = file:read_file(Index),
    {match, Hrefs} = re:run(Bin, "href=\"([^\"]+)\"",
			    [global, {capture, [1], list}, unicode]),
    Base = filename:dirname(Index),
    Paths = [resolve_href(Base, H) || [H] <- Hrefs,
				      string:find(H, Needle) =/= nomatch],
    true = Paths =/= [],
    lists:foreach(fun(Path) ->
			  true = filelib:is_file(Path)
		  end, Paths).

resolve_href(Base, Href) ->
    Path = uri_string:unquote(Href),
    case filename:pathtype(Path) of
	absolute -> Path;
	_ -> filename:join(Base, Path)
    end.

assert_junit(JunitFile, Jobs) ->
    Text = read_text(JunitFile),
    lists:foreach(fun(#{id := bad}) ->
			  ok;
		     (#{mod := Mod, tc := Case}) ->
			  true = nomatch =/= string:find(Text, atom_to_list(Mod)),
			  true = nomatch =/= string:find(Text,
							 "name=\"" ++ atom_to_list(Case) ++ "\"")
		  end, Jobs),
    {ok, Bin} = file:read_file(JunitFile),
    {match, Logs} = re:run(Bin, "log=\"([^\"]+)\"",
			   [global, {capture, [1], list}, unicode]),
    Paths = [uri_string:unquote(L) || [L] <- Logs],
    true = Paths =/= [],
    lists:foreach(fun(Path) ->
			  true = filelib:is_file(Path),
			  lists:foreach(fun(Part) ->
						true = nbytes(Part) =< ?name_max
					end, filename:split(Path))
		  end, Paths).

%% Called after the second run. close/1 persists the cache taken at that
%% run's start, which has already scanned the first run's directories.
assert_cache_keys(LogDir, Jobs) ->
    {ok, Bin} = file:read_file(filename:join(LogDir, "ct_log_cache")),
    {log_cache, _Vsn, _Runs, Tests} = binary_to_term(Bin),
    Names = [Name || {Name, _, _, _, _} <- Tests],
    Expected = lists:sort([L || #{logical := L} <- Jobs] ++
			      ["legacy_ok", "ordinary", "hashed-logical"]),
    Expected = lists:sort(Names),
    true = lists:all(fun(Name) -> not shortened_stem(Name) end, Names).

planted_run(Name) ->
    string:find(Name, "legacy@") =/= nomatch orelse
	string:find(Name, "decoy@") =/= nomatch.

shortened_stem(Stem) ->
    case string:find(Stem, "~", trailing) of
	[$~ | Hex] ->
	    length(Hex) =:= 32 andalso
		lists:all(fun(C) ->
				  (C >= $0 andalso C =< $9) orelse
				      (C >= $a andalso C =< $f)
			  end, Hex);
	_ ->
	    false
    end.

assert_legacy(LogDir) ->
    Html = read_text(filename:join(LogDir, "index.html")),
    true = nomatch =/= string:find(Html, ">legacy_ok</a>"),
    All = read_text(filename:join(LogDir, "all_runs.html")),
    true = nomatch =/= string:find(All, "legacy_ok"),
    [Dir] = [D || {D, "legacy_ok"} <- found_jobs(LogDir)],
    false = filelib:is_file(filename:join(Dir, "ct_job_name")).

%%%-----------------------------------------------------------------
%%% Helpers
%%%-----------------------------------------------------------------

found_jobs(LogDir) ->
    Dirs = filelib:wildcard(filename:join(LogDir, "ct_run.*/*.logs")),
    [{D, read_logical(D)} || D <- Dirs].

read_logical(Dir) ->
    Base = filename:basename(Dir, ".logs"),
    case shortened_stem(Base) andalso
	filelib:is_file(filename:join(Dir, "ct_job_name")) of
	true -> read_sidecar(Dir);
	false -> Base
    end.

read_sidecar(Dir) ->
    {ok, Utf8} = file:read_file(filename:join(Dir, "ct_job_name")),
    Name = unicode:characters_to_list(Utf8, utf8),
    true = is_list(Name),
    Name.

run_dirs(Dir) ->
    filelib:wildcard(filename:join(Dir, "run.*")).

read_text(File) ->
    {ok, Bin} = file:read_file(File),
    unicode:characters_to_list(Bin, utf8).

row_containing(Html, Logical) ->
    Rows = string:split(Html, "<tr", all),
    case [Row || Row <- Rows, string:find(Row, Logical) =/= nomatch] of
	[Row | _] -> Row;
	[] -> ct:fail({missing_row, Logical})
    end.

job_by(Id, Jobs) ->
    [Job] = [J || J = #{id := I} <- Jobs, I =:= Id],
    Job.

nbytes(Chars) ->
    byte_size(unicode:characters_to_binary(Chars, unicode,
					   file:native_name_encoding())).
