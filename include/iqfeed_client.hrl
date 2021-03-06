-ifndef(IQFEED_CLIENT_HRL).
-define(IQFEED_CLIENT_HRL, true).

-include_lib("rz_util/include/rz_util.hrl").

-record(tick, {
  name :: binary(),
  last_price :: float(),
  last_vol :: integer(),
  time :: pos_integer(),
  bid :: float(),
  ask :: float()
}).

-type(tick_fun() :: fun((Tick :: #tick{}) -> ok)).

-type on_history_data() :: {data, {TimeUTC :: non_neg_integer(), #candle{}}} | end_of_data | {error, Reason :: any()}.
-type on_history_fun() :: fun((Data :: on_history_data()) -> ok).
-type get_history_reply() :: ok | {error, not_connected} | {error, getting_data}.

-endif.