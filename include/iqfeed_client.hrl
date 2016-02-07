-type(instr_name() :: string() | binary()).

-record(tick, {
  name :: binary(),
  last_price :: float(),
  last_vol :: integer(),
  time :: pos_integer(),
  bid :: float(),
  ask :: float()
}).

-type(tick_fun() :: fun((Tick :: #tick{}) -> ok)).