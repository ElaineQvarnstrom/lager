%% Copyright (c) 2011 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.

-module(lager_crash_log).

-behaviour(gen_server).

%% callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
        code_change/3]).

-export([start_link/1, start/1]).

-record(state, {
        name,
        fd,
        inode
    }).

start_link(Filename) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Filename], []).

start(Filename) ->
    gen_server:start({local, ?MODULE}, ?MODULE, [Filename], []).

init([Filename]) ->
    case lager_util:open_logfile(Filename, false) of
        {ok, {FD, Inode}} ->
            {ok, #state{name=Filename, fd=FD, inode=Inode}};
        Error ->
            Error
    end.

handle_call(_Call, _From, State) ->
    {reply, ok, State}.

handle_cast({log, Event}, #state{name=Name, fd=FD, inode=Inode} = State) ->
    FmtMaxBytes = 1024,
    TermMaxSize = 500,
    %% borrowed from riak_err
    {ReportStr, Pid, MsgStr, _ErrorP} = case Event of
        {error, _GL, {Pid1, Fmt, Args}} ->
            {"ERROR REPORT", Pid1, limited_fmt(Fmt, Args, TermMaxSize, FmtMaxBytes), true};
        {error_report, _GL, {Pid1, std_error, Rep}} ->
            {"ERROR REPORT", Pid1, limited_str(Rep, FmtMaxBytes), true};
        {error_report, _GL, Other} ->
            perhaps_a_sasl_report(error_report, Other, FmtMaxBytes);
        _ ->
            {ignore, ignore, ignore, false}
    end,
    if ReportStr == ignore ->
            {noreply, State};
        true ->
            case lager_util:ensure_logfile(Name, FD, Inode, false) of
                {ok, {NewFD, NewInode}} ->
                    Time = [lager_util:format_time(
                            lager_stdlib:maybe_utc(erlang:localtime())),
                        " =", ReportStr, "====\n"],
                    NodeSuffix = other_node_suffix(Pid),
                    file:write(NewFD, io_lib:format("~s~s~s", [Time, MsgStr, NodeSuffix])),
                    {noreply, State#state{fd=NewFD, inode=NewInode}};
                Error ->
                    lager:log(error, self(), "Failed to reopen crash log file ~w with error ~w", [Name, Error]),
                    {noreply, State}
            end
    end;
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ===== Begin code lifted from riak_err =====

-spec limited_fmt(string(), list(), integer(), integer()) -> iolist().
%% @doc Format Fmt and Args similar to what io_lib:format/2 does but with 
%%      limits on how large the formatted string may be.
%%
%% If the Args list's size is larger than TermMaxSize, then the
%% formatting is done by trunc_io:print/2, where FmtMaxBytes is used
%% to limit the formatted string's size.

limited_fmt(Fmt, Args, TermMaxSize, FmtMaxBytes) ->
    TermSize = erts_debug:flat_size(Args),
    if TermSize > TermMaxSize ->
            ["Oversize args for format \"", Fmt, "\": \n",
                [
                    begin
                            {Str, _} = trunc_io:print(lists:nth(N, Args), FmtMaxBytes),
                            ["  arg", integer_to_list(N), ": ", Str, "\n"]
                    end || N <- lists:seq(1, length(Args))
                ]];
        true ->
            io_lib:format(Fmt, Args)
    end.

limited_str(Term, FmtMaxBytes) ->
    {Str, _} = trunc_io:print(Term, FmtMaxBytes),
    Str.

other_node_suffix(Pid) when node(Pid) =/= node() ->
    "** at node " ++ atom_to_list(node(Pid)) ++ " **\n";
other_node_suffix(_) ->
    "".

perhaps_a_sasl_report(error_report, {Pid, Type, Report}, FmtMaxBytes) ->
    case lager_stdlib:is_my_error_report(Type) of
        true ->
            {sasl_type_to_report_head(Type), Pid,
                sasl_limited_str(Type, Report, FmtMaxBytes), true};
        false ->
            {ignore, ignore, ignore, false}
    end;
perhaps_a_sasl_report(info_report, {Pid, Type, Report}, FmtMaxBytes) ->
    case lager_stdlib:is_my_info_report(Type) of
        true ->
            {sasl_type_to_report_head(Type), Pid,
                sasl_limited_str(Type, Report, FmtMaxBytes), false};
        false ->
            {ignore, ignore, ignore, false}
    end;
perhaps_a_sasl_report(_, _, _) ->
    {ignore, ignore, ignore, false}.

sasl_type_to_report_head(supervisor_report) ->
    "SUPERVISOR REPORT";
sasl_type_to_report_head(crash_report) ->
    "CRASH REPORT";
sasl_type_to_report_head(progress) ->
    "PROGRESS REPORT".

sasl_limited_str(supervisor_report, Report, FmtMaxBytes) ->
    Name = lager_stdlib:sup_get(supervisor, Report),
    Context = lager_stdlib:sup_get(errorContext, Report),
    Reason = lager_stdlib:sup_get(reason, Report),
    Offender = lager_stdlib:sup_get(offender, Report),
    FmtString = "     Supervisor: ~p~n     Context:    ~p~n     Reason:     "
    "~s~n     Offender:   ~s~n~n",
    {ReasonStr, _} = trunc_io:print(Reason, FmtMaxBytes),
    {OffenderStr, _} = trunc_io:print(Offender, FmtMaxBytes),
    io_lib:format(FmtString, [Name, Context, ReasonStr, OffenderStr]);
sasl_limited_str(progress, Report, FmtMaxBytes) ->
    [begin
                {Str, _} = trunc_io:print(Data, FmtMaxBytes),
                io_lib:format("    ~16w: ~s~n", [Tag, Str])
        end || {Tag, Data} <- Report];
sasl_limited_str(crash_report, Report, FmtMaxBytes) ->
    lager_stdlib:proc_lib_format(Report, FmtMaxBytes).

