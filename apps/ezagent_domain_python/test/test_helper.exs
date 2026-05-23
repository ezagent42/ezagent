# Skip the @uv-tagged integration tests by default when uv is not on
# the host's $PATH. Allen-decided default per SPEC §9.2: integration
# runs locally if uv is installed, CI gates separately.
exclude =
  case System.find_executable("uv") do
    nil -> [exclude: [:uv]]
    _ -> []
  end

ExUnit.start(exclude)
