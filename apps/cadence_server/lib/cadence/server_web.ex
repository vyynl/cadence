defmodule Cadence.ServerWeb do
  @moduledoc """
  Web-layer conveniences shared by the server's endpoint, router, controllers,
  and LiveViews.
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

      use Phoenix.VerifiedRoutes,
        endpoint: Cadence.ServerWeb.Endpoint,
        router: Cadence.ServerWeb.Router,
        statics: ~w(assets)
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView, layout: {Cadence.ServerWeb.Layouts, :app}

      import Phoenix.HTML
      alias Phoenix.HTML.Tag

      use Phoenix.VerifiedRoutes,
        endpoint: Cadence.ServerWeb.Endpoint,
        router: Cadence.ServerWeb.Router,
        statics: ~w(assets)
    end
  end

  def router do
    quote do
      use Phoenix.Router

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end
end
