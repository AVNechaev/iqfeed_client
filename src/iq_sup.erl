%%%-------------------------------------------------------------------
%%% @author anechaev
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 02. Feb 2016 21:06
%%%-------------------------------------------------------------------
-module(iq_sup).
-author("anechaev").

-behaviour(supervisor).

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

-include("iqfeed_client.hrl").
-define(SERVER, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================
-spec(start_link(TickFun :: tick_fun()) -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link(TickFun) ->
  supervisor:start_link({local, ?SERVER}, ?MODULE, [TickFun]).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================
init([TickFun]) ->
  IQLevel1 = {iql1_conn,
    {iql1_conn, start_link, [
      TickFun,
      iqfeed_util:get_env(iqfeed_client, iqfeed_ip),
      iqfeed_util:get_env(iqfeed_client, iqfeed_l1_port),
      [] %% initial instruments
    ]},
    permanent, brutal_kill, worker, [iql1_conn]
  },

  {ok, {
    {one_for_one, 0, 60},
    [
      IQLevel1
    ]}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
