%%%-------------------------------------------------------------------
%%% @author anechaev
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 02. Feb 2016 22:06
%%%-------------------------------------------------------------------
-module(iq_test).
-author("anechaev").

%% API
-export([run/0]).

run() ->
  application:set_env(lager, handlers, [{lager_console_backend, info}]),
  lager:start(),
  application:set_env(iqfeed_client, iqfeed_ip, "127.0.0.1"),
  application:set_env(iqfeed_client, iqfeed_port, 5009),
  iq_sup:start_link(),
  iq_ifc:update_instrs("/home/anechaev/tmp/iqinstr.csv"),
  ok.