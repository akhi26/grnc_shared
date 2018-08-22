# GrncShared

Shared code between GrncHub and GrncServer

**RequestLogger logs a lot of info, make sure you setup logrotate**
**The x-request-id header can be used to grep for logs**

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed as:

  1. Add `grnc_shared` to your list of dependencies in `mix.exs`:

    ```elixir
    def deps do
      [{:grnc_shared, "~> 0.1.0"}]
    end
    ```

  2. Ensure `grnc_shared` is started before your application:

    ```elixir
    def application do
      [applications: [:grnc_shared]]
    end
    ```

