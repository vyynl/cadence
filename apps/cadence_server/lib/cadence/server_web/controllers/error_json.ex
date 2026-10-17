defmodule Cadence.ServerWeb.ErrorJSON do
  @moduledoc """
  JSON error rendering for the endpoint.
  """

  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
