defmodule Nerves.System.Squashfs do
  use GenServer

  require Logger

  @file_types ["c", "b", "l", "d", "-"]
  @device_types ["c", "b"]
  @posix [r: 4, w: 2, x: 1, s: 1, t: 1]
  @sticky ["s", "t", "S", "T"]

  def start_link(rootfs) do
    params = unsquashfs(rootfs)
    dir = Path.dirname(rootfs)
    case System.cmd("unsquashfs", [rootfs]) do
      {result, 0} ->
        GenServer.start_link(__MODULE__, [rootfs, params])
      {error, _} = reply ->
        {:error, error}
    end
  end

  def stop(pid) do
    GenServer.call(pid, :stop)
    GenServer.stop(pid)
  end

  def pseudofile(pid) do
    GenServer.call(pid, {:pseudofile})
  end

  def pseudofile_fragment(pid, fragment) do
    GenServer.call(pid, {:pseudofile_fragment, fragment})
  end

  def fragment(pid, fragment, path) do
    GenServer.call(pid, {:fragment, fragment, path})
  end

  def files(pid) do
    GenServer.call(pid, {:files})
  end

  def unsquashfs(rootfs) do
    case System.cmd("unsquashfs", ["-n", "-ll", rootfs]) do
      {result, 0} ->
        String.split(result, "\n")
        |> parse
      {error, _} -> raise "Error parsing Rootfs: #{inspect error}"
    end
  end

  def init([rootfs, params]) do

    {:ok, %{
      rootfs: rootfs,
      params: params,
      stage: Path.join(File.cwd!, "squashfs-root")
    }}
  end

  def handle_call(:stop, from, s) do
    File.rm_rf!(s.stage)
    {:reply, :ok, s}
  end

  def handle_call({:files}, from, s) do
    files = Enum.reduce(s.params, [], fn
      {"d", file, _, _, _}, acc -> acc
      {_, file, _, _, _}, acc -> [file | acc]
    end)
    {:reply, files, s}
  end

  def handle_call({:pseudofile}, from, s) do
    {:reply, params_to_pseudofile(s.params), s}
  end

  def handle_call({:pseudofile_fragment, fragment}, from, s) do
    fragment = Enum.filter(s.params, fn
      {_, file, _, _, _} -> file in fragment
    end)
    {:reply, params_to_pseudofile(fragment), s}
  end

  def handle_call({:fragment, fragment, path}, from, s) do
    fragment
    |> Enum.map(&Path.dirname/1)

    fragment = Enum.filter(s.params, fn
      {_, file, _, _, _} -> file in fragment
    end)

    pseudofile = params_to_pseudofile(fragment)
    tmp_dir = Path.dirname(path)
    |> Path.join("tmp")
    File.mkdir_p!(tmp_dir)

    pseudofile_path =
      Path.dirname(path)
      |> Path.join("pseudofile")
    File.write!(pseudofile_path, pseudofile)

    Enum.each(fragment, fn({_, file, _, _, _}) ->
      src = Path.join(s.stage, file)
      dest = Path.join(tmp_dir, file)
      Path.dirname(dest)
      |> File.mkdir_p!
      File.cp!(src, dest)
    end)
    IO.puts path
    System.cmd("mksquashfs", [tmp_dir, path, "-pf", pseudofile_path, "-noappend", "-no-recovery", "-no-progress"])
    File.rm_rf!(tmp_dir)
    #File.rm!(pseudofile_path)

    {:reply, {:ok, path}, s}
  end

  defp params_to_pseudofile(fragment) do
    Enum.map(fragment, fn
      {type, file, {major, minor}, {p0, p1, p2, p3}, {o, g}} when type in @device_types ->
        "#{file} #{type} #{p0}#{p1}#{p2}#{p3} #{o} #{g} #{major} #{minor}"
      {type, file, attr, {p0, p1, p2, p3}, {o, g}} ->
        file = if file == "", do: "/", else: file
        "#{file} m #{p0}#{p1}#{p2}#{p3} #{o} #{g}"
    end)
    |> Enum.reverse
    |> Enum.join("\n")
  end

  defp parse(_, _ \\ [])
  defp parse([], collect), do: collect
  defp parse([line | tail], collect) do
    collect =
      case parse_line(line) do
        nil -> collect
        value -> [value | collect]
      end
    parse(tail, collect)
  end

  defp parse_line(""), do: nil
  defp parse_line(<<type :: binary-size(1), permissions :: binary-size(9), _ :: utf8, tail :: binary>>)
    when type in @file_types do
    permissions = parse_permissions(permissions)
    [own, tail] = String.split(tail, " ", parts: 2)
    own = parse_own(own)
    tail = String.strip(tail)

    {attr, tail} =
    if type in @device_types do
      [major, tail] = String.split(tail, ",", parts: 2)
      tail = String.strip(tail)
      [minor, tail] = String.split(tail, " ", parts: 2)
      {{major, minor}, tail}
    else
      [_, tail] = String.split(tail, " ", parts: 2)
      {nil, tail}
    end

    <<modified :: binary-size(16), tail :: binary>> = tail
    <<"squashfs-root", file :: binary>> = String.strip(tail)
    file =
      if type == "l" do
        [file, _] = String.split(file, "->")
        String.strip(file)
      else
        file
      end
    {type, file, attr, permissions, own}
  end
  defp parse_line(_), do: nil

  defp parse_permissions(<<owner :: binary-size(3), group :: binary-size(3), other :: binary-size(3)>>) do
    sticky = 0
    sticky = sticky + sticky_to_int(owner, 4) + sticky_to_int(group, 2) + sticky_to_int(other, 1)
    {sticky, posix_to_int(owner), posix_to_int(group), posix_to_int(other)}
  end

  defp parse_own(own) do
    [owner, group] = String.split(own, "/")
    {owner, group}
  end

  defp sticky_to_int(<<_ :: binary-size(1), _ :: binary-size(1), bit :: binary-size(1)>>, weight)
    when bit in @sticky, do: weight
  defp sticky_to_int(_, _), do: 0

  defp posix_to_int(<<r :: binary-size(1), w :: binary-size(1), x :: binary-size(1)>>) do
    Enum.reduce([r, w, x], 0, fn(p, a) ->
      Keyword.get(@posix, String.to_atom(p), 0) + a
    end)
  end

  def path_to_paths(path) do
    path
    |> Path.dirname
    |> Path.split
    |> Enum.reduce(["/"], fn(p, acc) ->
      [h | _t] = acc
      [Path.join(h, p) | acc]
    end)
  end
end