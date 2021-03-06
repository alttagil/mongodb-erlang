%%%-------------------------------------------------------------------
%%% @author Alexander Hudich (alttagil@gmail.com)
%%% @copyright (C) 2015, Alexander Hudich
%%% @doc
%%% mongoc internal module for handling server's connection pool and monitoring
%%% @end
%%%-------------------------------------------------------------------
-module(mc_server).
-author("alttagil@gmail.com").

-behaviour(gen_server).

-include("mongoc.hrl").

%% API
-export([start_link/4, start/4, get_pool/1, update_ismaster/2, update_unknown/1]).

%% gen_server callbacks
-export([init/1,
	handle_call/3,
	handle_cast/2,
	handle_info/2,
	terminate/2,
	code_change/3]).

-define(SERVER, ?MODULE).

-record( state, {
					host, port,

					rs = undefined,
					type = undefined,

					me,

					min_pool,
					max_pool,
					connect_to,
					socket_to,
					waitqueue_to,
					topology,
					topology_mref,
					topology_opts = [],
					worker_opts = [],

					ismaster = undefined,

					monitor = undefined,
					pool = undefined
				} ).

%%%===================================================================
%%% API
%%%===================================================================

start_link( Topology, HostPort, Topts, Wopts ) ->
	gen_server:start_link( ?MODULE, [Topology, HostPort, Topts, Wopts], []).

start( Topology, HostPort, Topts, Wopts ) ->
	gen_server:start( ?MODULE, [Topology, HostPort, Topts, Wopts], []).


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================



init([Topology, Addr, TopologyOptions, Wopts]) ->

	process_flag(trap_exit, true),

	{Host, Port} = parse_seed( Addr ),

	MinPoolSize =  proplists:get_value( minPoolSize, TopologyOptions, 5 ),
	MaxPoolSize =  proplists:get_value( maxPoolSize, TopologyOptions, 10 ),

	ConnectTimeoutMS =  proplists:get_value( connectTimeoutMS, TopologyOptions, 20000 ),
	SocketTimeoutMS =  proplists:get_value( socketTimeoutMS, TopologyOptions, 100 ),
	WaitQueueTimeoutMS =  proplists:get_value( waitQueueTimeoutMS, TopologyOptions, 1000 ),

	ReplicaSet = proplists:get_value( rs, TopologyOptions, undefined ),

	MRef = erlang:monitor( process, Topology ),

	gen_server:cast( self(), init_monitor ),


	{ok, #state{

		topology = Topology,
		topology_mref = MRef,

		host = Host,
		port = Port,

		rs = ReplicaSet,

		waitqueue_to = WaitQueueTimeoutMS,

		min_pool = MinPoolSize,
		max_pool = MaxPoolSize,
		connect_to = ConnectTimeoutMS,
		socket_to = SocketTimeoutMS,

		topology_opts = TopologyOptions,
		worker_opts = Wopts
	} }.


terminate(_Reason,  #state{ topology = Topology } = _State) ->
	mc_topology:drop_server( Topology, self() ),
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.




%%%===================================================================
%%% External functions
%%%===================================================================


get_pool( Pid ) ->
	gen_server:call( Pid, get_pool ).

update_ismaster( Pid, { Type, IsMaster } ) ->
	gen_server:cast( Pid, { update_ismaster, Type, IsMaster } ).

update_unknown( Pid  ) ->
	gen_server:cast( Pid, { update_unknown } ).

%%%===================================================================
%%% Handlers
%%%===================================================================

handle_call(get_pool, _From, #state{ type = unknown } = State ) ->
	{reply, {error, server_unknown}, State };

handle_call(get_pool, _From, #state{ ismaster = undefined } = State ) ->
	{reply, {error, server_unknown}, State };

handle_call(get_pool, _From, #state{ pool = undefined } = State ) ->
	{ok, Pid} = init_pool( State ),
	{reply, Pid, State#state{ pool = Pid } };

handle_call(get_pool, _From, #state{ pool = Pid } = State ) ->
	{reply, Pid, State };


handle_call(_Request, _From, State) ->
	{reply, ok, State}.




handle_cast( init_monitor, State ) ->
	{ ok, Pid } = init_monitor( State ),
	{noreply, State#state{ monitor = Pid } };


handle_cast( start_pool, #state{ pool = undefined } = State ) ->
	{ ok, Pid } = init_pool( State ),
	{noreply, State#state{ pool = Pid } };


handle_cast( { update_ismaster, Type, IsMaster }, #state{ monitor = undefined } = State ) ->
	{noreply, State#state{ type = Type, ismaster = IsMaster } };

handle_cast( { update_ismaster, Type, IsMaster }, #state{ monitor = Monitor } = State ) ->
	mc_monitor:update_type( Monitor, Type ),
	{noreply, State#state{ type = Type, ismaster = IsMaster } };


handle_cast( { update_unknown }, #state{ monitor = Monitor, pool = undefined } = State ) ->
	mc_monitor:update_type( Monitor, unknown ),
	{noreply, State#state{ pool = undefined, type = unknown, ismaster = undefined } };

handle_cast( { update_unknown }, #state{ monitor = Monitor, pool = Pool } = State ) ->
	erlang:unlink( Pool ),
	erlang:exit( Pool, kill ),
	mc_monitor:update_type( Monitor, unknown ),
	{noreply, State#state{ pool = undefined, type = unknown, ismaster = undefined } };


handle_cast(_Request, State) ->
	{noreply, State}.



handle_info({'DOWN', MRef, _, _, _}, #state{ topology_mref = MRef } = State) ->
	exit( kill ),
	{noreply, State};

handle_info({'EXIT', Pid, _Reason}, #state{ topology = Topology, pool = Pid } = State) ->
	gen_server:cast( Topology, { server_to_unknown, self() } ),
	{noreply, State#state{ pool = undefined } };

handle_info({'EXIT', Pid, _Reason}, #state{ monitor = Pid } = State) ->
	exit( kill ),
	{noreply, State};


handle_info(_Info, State) ->
	{noreply, State}.





%%%===================================================================
%%% Internal functions
%%%===================================================================


init_monitor( #state{ topology = Topology, host = Host, port = Port, topology_opts = Topts, worker_opts = Wopts } = _State ) ->
	mc_monitor:start_link( Topology, self(), { Host, Port }, Topts, Wopts ).


init_pool( #state{ host = Host, port = Port, min_pool = MinPool, max_pool = MaxPool, worker_opts = Wopts, waitqueue_to = WQ  } = _State ) ->
	PoolOptions = [ { min_pool_size, MinPool }, { max_pool_size, MaxPool }, { mondemand, false }, {request_max_wait, WQ } ],
	WO = lists:append( [{host, Host}, {port, Port}, {proxy, true}], Wopts ),
	gen_server_pool:start_link ( mc_worker, WO, [], PoolOptions ).



parse_seed( Addr ) when is_binary( Addr ) ->
	parse_seed( binary_to_list( Addr ) );
parse_seed( Addr ) when is_list( Addr ) ->
	[Host,Port] = string:tokens( Addr, ":" ),
	{ Host, list_to_integer( Port ) }.


