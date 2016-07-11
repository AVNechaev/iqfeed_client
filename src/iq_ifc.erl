%%%-------------------------------------------------------------------
%%% @author anechaev
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 02. Feb 2016 21:49
%%%-------------------------------------------------------------------
-module(iq_ifc).
-author("anechaev").

%% API
-export([update_instrs/1]).

%%--------------------------------------------------------------------
update_instrs(FileName) ->
  {ok, I} = rz_util:load_instr_csv(FileName),
  iql1_conn:set_instrs(I).