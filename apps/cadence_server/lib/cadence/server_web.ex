defmodule Cadence.ServerWeb do
  @moduledoc """
  Web-layer conveniences shared by the server's endpoint, router, and
  controllers.
  """

  defmacro __using__(which) do
    apply(__MODULE__, which, [])
  end

  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:html, :json],
        layouts: [html: Cadence.ServerWeb.Layouts]

      import Plug.Conn
      import Cadence.ServerWeb.JSON
    end
  end

  def html do
    quote do
      use Phoenix.Component
      import Phoenix.HTML
      alias Phoenix.HTML.Tag
    end
  end

  def router do
    quote do
      use Phoenix.Router

      import Plug.Conn
      import Phoenix.Controller
    end
  end
end
