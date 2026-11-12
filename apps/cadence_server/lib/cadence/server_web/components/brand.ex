defmodule Cadence.ServerWeb.Components.Brand do
  @moduledoc """
  The Cadence mark: a small DAG fork (one root node branching to two children).

  It is an inline SVG so it inherits the surrounding text color, needs no font
  or network request, and reads at favicon size. The wordmark stays typographic.
  """

  use Phoenix.Component

  attr :size, :integer, default: 20
  attr :class, :string, default: nil
  attr :title, :string, default: nil

  def logo(assigns) do
    ~H"""
    <svg
      viewBox="0 0 24 24"
      width={@size}
      height={@size}
      class={@class}
      role={if @title, do: "img", else: "presentation"}
      aria-hidden={if @title, do: nil, else: "true"}
      focusable="false"
    >
      <title :if={@title}>{@title}</title>
      <rect x="1" y="1" width="22" height="22" rx="6" fill="currentColor" opacity="0.12" />
      <path
        d="M9.2 11.2 14.9 8.3M9.2 12.8 14.9 15.7"
        stroke="currentColor"
        stroke-width="1.6"
        stroke-linecap="round"
      />
      <circle cx="7.2" cy="12" r="2.3" fill="currentColor" />
      <circle cx="17.2" cy="7.6" r="2.3" fill="currentColor" />
      <circle cx="17.2" cy="16.4" r="2.3" fill="currentColor" />
    </svg>
    """
  end
end
