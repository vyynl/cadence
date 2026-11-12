defmodule Cadence.ServerWeb.ErrorHTML do
  @moduledoc """
  HTML error pages for browser requests.
  """

  use Cadence.ServerWeb, :html

  def render("404.html", _assigns) do
    assigns = %{}

    ~H"""
    <article>
      <p class="eyebrow">404</p>
      <h1>Page not found</h1>
      <p class="note">There is nothing at this address.</p>
      <p><a class="button-link" href="/">Back to Cadence</a></p>
    </article>
    """
  end

  def render("500.html", _assigns) do
    assigns = %{}

    ~H"""
    <article>
      <p class="eyebrow">500</p>
      <h1>Something went wrong</h1>
      <p class="note">The server could not complete this request.</p>
      <p><a class="button-link" href="/">Back to Cadence</a></p>
    </article>
    """
  end

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
