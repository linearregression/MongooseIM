-module(mod_amp).
%% @doc MongooseIM/Ejabberd module for (a subset of) XEP-0079 support.
%% @reference <a href="http://xmpp.org/extensions/xep-0079.html">XEP-0079</a>
%% @author <mongooseim@erlang-solutions.com>
%% @copyright 2014 Erlang Solutions, Ltd.
%% This work was sponsored by Grindr LLC

-behavior(gen_mod).

-export([start/2, stop/1]).
-export([add_local_features/5,
         add_stream_feature/2,
         filter_packet/1
        ]).

-include_lib("ejabberd/include/amp.hrl").
-include_lib("ejabberd/include/ejabberd.hrl").
-include_lib("ejabberd/include/jlib.hrl").

-type hook_data() :: {jid(),jid(),#xmlel{}} | drop.

-define(AMP_FEATURE,
        #xmlel{name = <<"amp">>, attrs = [{<<"xmlns">>, ?NS_AMP_FEATURE}]}).
-define(AMP_RESOLVER, amp_resolver).
-define(AMP_STRATEGY, amp_strategy).

start(Host, _Opts) ->
    mod_disco:register_feature(Host, ?NS_AMP),
    ejabberd_hooks:add(c2s_stream_features, Host, ?MODULE, add_stream_feature, 50),
    ejabberd_hooks:add(disco_local_features, Host, ?MODULE, add_local_features, 99),
    ejabberd_hooks:add(filter_packet, global, ?MODULE, filter_packet, 49),
    ejabberd_hooks:add(amp_verify_support, Host, ?AMP_RESOLVER, verify_support, 49),
    ejabberd_hooks:add(amp_check_condition, Host, ?AMP_RESOLVER, check_condition, 49),
    ejabberd_hooks:add(amp_determine_strategy, Host, ?AMP_STRATEGY, determine_strategy, 49).

stop(Host) ->
    ejabberd_hooks:delete(amp_determine_strategy, Host, ?AMP_STRATEGY, determine_strategy, 49),
    ejabberd_hooks:delete(amp_check_condition, Host, ?AMP_RESOLVER, check_condition, 49),
    ejabberd_hooks:delete(amp_verify_support, Host, ?AMP_RESOLVER, verify_support, 49),
    ejabberd_hooks:delete(filter_packet, global, ?MODULE, filter_packet, 49),
    ejabberd_hooks:delete(disco_local_features, Host, ?MODULE, add_local_features, 99),
    ejabberd_hooks:delete(c2s_stream_features, Host, ?MODULE, add_stream_feature, 50),
    mod_disco:unregister_feature(Host, ?NS_AMP).

%% Business API
add_local_features(Acc, _From, _To, ?NS_AMP, _Lang) ->
    Features = result_or(Acc, []) ++ amp_features(),
    {result, Features};
add_local_features(Acc, _From, _To, <<>>, _Lang) ->
    Acc.

add_stream_feature(Acc, _Host) ->
    lists:keystore(<<"amp">>, #xmlel.name, Acc, ?AMP_FEATURE).

-spec filter_packet(hook_data()) -> hook_data().
filter_packet(drop) -> drop;
filter_packet({From, To, #xmlel{name = <<"message">>} = Packet} = HookData) ->
    ?DEBUG("Receive packet~n    from ~p ~n    to ~p~n    packet ~p.",
           [From, To, Packet]),
    case amp:extract_requested_rules(Packet) of
        none                    -> HookData;
        {rules, Rules}          -> process_amp_rules(HookData, Rules);
        {errors, Errors}        -> send_errors_and_drop(HookData, Errors)
    end;
filter_packet(HookData) -> HookData.

%% @doc This may eventually be configurable, but for now we return a constant list.
amp_features() ->
    [<<"http://jabber.org/protocol/amp">>,
     <<"http://jabber.org/protocol/amp?action=notify">>,
     <<"http://jabber.org/protocol/amp?action=error">>,
     <<"http://jabber.org/protocol/amp?condition=deliver">>,
     <<"http://jabber.org/protocol/amp?condition=match-resource">>
    ].

-spec process_amp_rules(hook_data(), amp_rules()) -> hook_data().
process_amp_rules(HookData, Rules) ->
    Host = ?MYNAME,
    VerifiedRules = verify_support(Host, Rules),
    {Good,Bad} = lists:partition(fun is_supported_rule/1, VerifiedRules),
    ValidRules = [ Rule || {supported, Rule} <- Good ],
    case Bad of
        [{error, ValidationError, InvalidRule} | _] ->
            send_error_and_drop(HookData, ValidationError, InvalidRule);
        [] ->
            Strategy = determine_strategy(Host, HookData),
            process_one_by_one(HookData, Strategy, ValidRules)
    end.

%% @doc ejabberd_hooks helpers
-spec verify_support(binary(), amp_rules()) -> [amp_rule_support()].
verify_support(Host, Rules) ->
    ejabberd_hooks:run_fold(amp_verify_support, Host, [], [Rules]).

-spec determine_strategy(binary(), hook_data()) -> amp_strategy().
determine_strategy(Host, HookData) ->
    ejabberd_hooks:run_fold(amp_determine_strategy, Host,
                            amp_strategy:null_strategy(), [HookData]).

-spec resolve_condition(hook_data(), binary(), amp_strategy(),
                        amp_condition(), amp_value())
                       -> boolean().
resolve_condition(_HookData, Host, Strategy, Condition, Value) ->
    ejabberd_hooks:run_fold(amp_check_condition, Host, false,
                            [Strategy, Condition, Value]).

-spec process_one_by_one(hook_data(), amp_strategy(), amp_rules()) -> hook_data().
process_one_by_one(HookData, Strategy, ValidRules) ->
    case fold_apply_rules(HookData, ?MYNAME, Strategy, ValidRules) of
        'no_match' ->
            HookData;
        {match, #amp_rule{action='error'} = Rule} ->
            send_error_and_drop(HookData, 'undefined-condition', Rule);
        {match, Rule} ->
            take_action(HookData, Rule)
    end.

-spec fold_apply_rules(hook_data(), binary(), amp_strategy(), amp_rules())
                      -> amp_rule_match().
fold_apply_rules(_, _, _, []) -> 'no_match';
fold_apply_rules(HookData, Host, Strategy, [Rule|Rest]) ->
    #amp_rule{condition = C, value = V} = Rule,
    case resolve_condition(HookData, Host, Strategy, C, V) of
        true  -> {match, Rule};
        false -> fold_apply_rules(HookData, Host, Strategy, Rest)
    end.

-spec send_error_and_drop(hook_data(), amp_error(), amp_rule()) -> drop.
send_error_and_drop(HookData, AmpError, MatchedRule) ->
    send_errors_and_drop(HookData, [{AmpError, MatchedRule}]).

-spec send_errors_and_drop(hook_data(), [{amp_error(),amp_rule()}]) -> drop.
send_errors_and_drop(HookData, []) ->
    ?ERROR_MSG("~p generated an empty list of errors. This shouldn't happen!",
                 HookData),
    drop;

send_errors_and_drop({From, _To, Packet}, ErrorRules) ->
    ServerJid = jlib:binary_to_jid(?MYNAME),
    {Errors,Rules} = lists:unzip(ErrorRules),
    ErrorResponse = amp:make_error_response(Errors, Rules, From, Packet),
    ejabberd_router:route(ServerJid, From, ErrorResponse),
    drop.

-spec take_action(hook_data(), amp_rule()) -> hook_data().
take_action({From, To, Packet}, #amp_rule{action=Action} = Rule) ->
    ServerJid = jlib:binary_to_jid(?MYNAME),
    case Action of
        'notify' ->
            reply_to_sender(Rule, ServerJid, From, Packet),
            {From, To, amp:strip_amp_el(Packet)};
        _          -> drop
    end.

-spec reply_to_sender(amp_rule(), jid(), jid(), exml:xmlel()) -> ok.
reply_to_sender(MatchedRule, ServerJid, OriginalSender, OriginalPacket) ->
    Response = amp:make_response(MatchedRule, OriginalSender, OriginalPacket),
    ejabberd_router:route(ServerJid, OriginalSender, Response).


%% Internal
result_or({result, I},_) -> I;
result_or(_, Or)         -> Or.

-spec is_supported_rule(amp_rule_support()) -> boolean().
is_supported_rule({supported, _}) -> true;
is_supported_rule(_)              -> false.
