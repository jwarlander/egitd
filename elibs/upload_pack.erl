-module(upload_pack).
-export([handle/3]).

handle(Sock, Host, Header) ->
  try
    handle_upload_pack_impl(Sock, Host, Header)
  catch
    throw:{no_such_repo, Repo} ->
      handle_upload_pack_nosuchrepo(Sock, Repo);
    throw:{permission_denied, Repo} ->
      handle_upload_pack_permission_denied(Sock, Repo)
  end.

handle_upload_pack_impl(Sock, Host, Header) ->
  % extract and normalize the repo path
  {ok, Path} = extract_repo_path(Header),
  {ok, FullPath} = conf:convert_path(Host, Path),
  
  % io:format("fullpath = ~p~n", [FullPath]),
  
  % check for repo existence
  case file_exists(FullPath) of
    false -> throw({no_such_repo, FullPath});
    true -> ok
  end,
  
  % check for git-daemon-export-ok file
  GitDaemonExportOkFilePath = filename:join([FullPath, "git-daemon-export-ok"]),
  case file_exists(GitDaemonExportOkFilePath) of
    false -> throw({permission_denied, GitDaemonExportOkFilePath});
    true -> ok
  end,
  
  % make the port
  Command = "git upload-pack " ++ FullPath,
  Port = open_port({spawn, Command}, [binary]),
  
  % the initial output from git-upload-pack lists the SHA1s of each head.
  % data completion is denoted by "0000" on it's own line.
  % this is sent back immediately to the client.
  Index = gather_out(Port),
  % io:format("index = ~p~n", [Index]),
  gen_tcp:send(Sock, Index),
  
  % once the client receives the index data, it will demand that specific
  % revisions be packaged and sent back. this demand will be forwarded to
  % git-upload-pack.
  case gather_demand(Sock) of
    {ok, Demand} ->
      log_initial_clone(Demand, Host, Path),
      
      % io:format("+++~n~p~n+++~n", [Demand]),
      port_command(Port, Demand),
  
      % in response to the demand, git-upload-pack will stream out the requested
      % pack information. data completion is denoted by "0000".
      stream_out(Port, Sock),
      
      % close connections
      ok = gen_tcp:close(Sock),
      safe_port_close(Port);
    {error, closed} ->
      ok = gen_tcp:close(Sock),
      port_command(Port, "0000"),
      safe_port_close(Port),
      ok;
    {error, Reason} ->
      error_logger:error_msg("Client closed socket because: ~p~n", [Reason]),
      ok = gen_tcp:close(Sock),
      port_command(Port, "0000"),
      safe_port_close(Port)
  end.
  
safe_port_close(Port) ->
  unlink(Port),
  try port_close(Port)
  catch
    _:_ -> ok
  end.

handle_upload_pack_nosuchrepo(Sock, Repo) ->
  error_logger:info_msg("no such repo: ~p~n", [Repo]),
  ok = gen_tcp:close(Sock).
  
handle_upload_pack_permission_denied(Sock, Repo) ->
  error_logger:info_msg("permission denied to repo: ~p~n", [Repo]),
  ok = gen_tcp:close(Sock).

gather_demand(Sock) ->
  gather_demand(Sock, "").
gather_demand(Sock, DataSoFar) ->
  case gen_tcp:recv(Sock, 0) of
    {ok, Data} ->
      % io:format("data = ~p~n", [Data]),
      TotalData = DataSoFar ++ Data,
      case regexp:first_match(TotalData, "0009done\n$") of
        {match, _Start, _Length} ->
          {ok, TotalData};
        _Else ->
          gather_demand(Sock, TotalData)
      end;
    {error, Reason} ->
      {error, Reason}
  end.

gather_out(Port) ->
  gather_out(Port, [], pipe:new()).
gather_out(Port, DataSoFar, Pipe) ->
  % io:format("gather-out "),
  {ok, Data, P2} = read_chunk(Port, Pipe),
  % io:format("+++~n~p~n+++~n", [Data]),
  TotalData = lists:append(DataSoFar, [Data]),
  case Data =:= <<"0000">> of
    true ->
      list_to_binary(TotalData);
    false ->
      gather_out(Port, TotalData, P2)
  end.
  
stream_out(Port, Sock) ->
  stream_out(Port, Sock, pipe:new()).
  
stream_out(Port, Sock, Pipe) ->
  % io:format("stream out "),
  % io:format("+++~n~p~n+++~n", [Data]),
  {ok, Data, P2} = read_chunk(Port, Pipe),
  gen_tcp:send(Sock, Data),
  case Data =:= <<"0000">> of
    true ->
      done;
    false ->
      stream_out(Port, Sock, P2)
  end.
  
read_chunk(Port, Pipe) ->
  case pipe:size(Pipe) >= 4 of
    true ->
      {ok, ChunkSizeHex, P2} = pipe:read(4, Pipe),
      % io:format("chunk size hex = ~p~n", [ChunkSizeHex]),
      read_chunk_body(ChunkSizeHex, Port, P2);
    false ->
      {data, Data} = readline(Port),
      {ok, P2} = pipe:write(Data, Pipe),
      read_chunk(Port, P2)
  end.
  
read_chunk_body(<<"0000">>, _Port, Pipe) ->
  {ok, <<"0000">>, Pipe};
  
read_chunk_body(ChunkSizeHex, Port, Pipe) ->
  ChunkSize = convert_chunk_size(ChunkSizeHex),
  % io:format("chunk size = ~p~n", [ChunkSize]),
  case pipe:read(ChunkSize, Pipe) of
    {ok, Bin, P2} ->
      % io:format("chunk body = ~p~n", [Bin]),
      Data = concat_binary([ChunkSizeHex, Bin]),
      {ok, Data, P2};
    eof ->
      % io:format("chunk body eof~n", []),
      {data, Data} = readline(Port),
      {ok, P2} = pipe:write(Data, Pipe),
      read_chunk_body(ChunkSizeHex, Port, P2)
  end.
      
convert_chunk_size(ChunkSizeHex) ->
  {ok, [Size], []} = io_lib:fread("~16u", binary_to_list(ChunkSizeHex)),
  Size - 4.
  
readline(Port) ->
  receive
    {Port, {data, Data}} ->
      % io:format("readline = ~p~n", [Data]),
      {data, Data};
    Msg ->
      error_logger:error_msg("unknown message ~p~n", [Msg]),
      {error, Msg}
    after 15000 ->
      error_logger:error_msg("timed out waiting for port~n"),
      {error, timeout}
  end.
  
log_initial_clone(Demand, Host, Path) ->
  case regexp:first_match(Demand, "have") of
    {match ,_Start, _Length} ->
      ok;
    _Else ->
      ok = log:write("clone", [Host, Path])
  end.
  
extract_repo_path(Header) ->
  case regexp:match(Header, " /[^\000]+\000") of
    {match, Start, Length} ->
      {ok, string:substr(Header, Start + 2, Length - 3)};
    _Else ->
      invalid
  end.
  
file_exists(FullPath) ->
  case file:read_file_info(FullPath) of
    {ok, _Info} ->
      true;
    {error, _Reason} ->
      false
  end.