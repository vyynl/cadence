defmodule Cadence.ServerWeb.Components.Incident do
  @moduledoc """
  Open-incident panel for the review hub (spec §6.7, §7.2).

  The panel sits above the proposal queue because an open critical incident is
  what blocks approval. Severity carries its own badge and a left accent on the
  row, while the severity word itself stays visible so the state is never
  conveyed by color alone.

  `details` is not a rendering contract: only the closed whitelist (`patterns`,
  `sensitive paths`, `reason`) is shown, with the full reason wrapped instead of
  truncated. Unknown keys never reach the page.

  The caller owns authorization and the resolve event; the panel only decides
  which control label and style to show (proposal incidents are re-scanned,
  node/project incidents are acknowledged).
  """

  use Cadence.ServerWeb, :html

  alias Cadence.ServerWeb.Presentation
  alias Phoenix.LiveView.AsyncResult

  attr(:incidents, :any,
    required: true,
    doc: "the `assign_async` result for `Incidents.list_open/2`"
  )

  attr(:can_decide?, :boolean, required: true)
  attr(:project_slug, :string, required: true)
  attr(:max, :integer, required: true)

  def panel(assigns) do
    loaded? = match?(%AsyncResult{ok?: true}, assigns.incidents)
    incident_list = if loaded?, do: assigns.incidents.result, else: []

    assigns =
      assign(assigns,
        loaded?: loaded?,
        incident_list: incident_list,
        critical_count: Enum.count(incident_list, &(&1.severity == :critical))
      )

    ~H"""
    <section id="incidents-panel" class="incidents-panel">
      <div aria-live="polite">
        <div class="panel-heading">
          <h2>Open incidents</h2>
          <span :if={@loaded?} class="count-badge">{length(@incident_list)}</span>
        </div>

        <p :if={@critical_count > 0} class="critical-count">
          {@critical_count} critical {if @critical_count == 1, do: "incident", else: "incidents"} blocking approval.
        </p>
      </div>

      <.async_result :let={incidents} assign={@incidents}>
        <:loading>
          <p class="note">Loading incidents…</p>
        </:loading>

        <:failed>
          <p class="note">The incident list could not be loaded.</p>
        </:failed>

        <p :if={incidents == []} class="empty">No open incidents.</p>

        <ul :if={incidents != []} class="file-tree">
          <li
            :for={incident <- incidents}
            id={"incident-#{incident.id}"}
            class={["incident-row", severity_row_class(incident.severity)]}
          >
            <div class="incident-heading">
              <span class={Presentation.severity_badge_class(incident.severity)}>
                {incident.severity}
              </span>
              <span class="incident-kind">{kind_label(incident.kind)}</span>
              <span class="incident-title">{incident.title}</span>
            </div>

            <p class="node-meta">
              <span :if={incident.proposal_id}>
                <a href={~p"/p/#{@project_slug}/reviews/#{incident.proposal_id}"}>Proposal</a>
              </span>
              <span :if={incident.node_id}>
                <a href={~p"/p/#{@project_slug}/n/#{incident.node_id}"}>Node</a>
              </span>
              <span :if={is_nil(incident.proposal_id) and is_nil(incident.node_id)}>
                Project-wide
              </span>
              <span :if={incident.created_at}>
                opened
                <time datetime={DateTime.to_iso8601(incident.created_at)}>
                  {Presentation.age(incident.created_at)}
                </time>
              </span>
            </p>

            <dl :if={details_pairs(incident.details) != []} class="incident-details">
              <%= for {label, value} <- details_pairs(incident.details) do %>
                <dt>{label}</dt>
                <dd>{value}</dd>
              <% end %>
            </dl>

            <div :if={@can_decide?} class="incident-actions">
              <button
                type="button"
                class={resolution_button_class(incident)}
                phx-click="resolve_incident"
                phx-value-id={incident.id}
                phx-disable-with="Resolving…"
              >
                {resolution_label(incident)}
              </button>
              <span class="incident-hint">{resolution_hint(incident)}</span>
            </div>
          </li>
        </ul>

        <p :if={length(incidents) == @max} class="note">
          Showing the {@max} newest open incidents.
        </p>
      </.async_result>
    </section>
    """
  end

  defp resolution_label(%{proposal_id: nil}), do: "Acknowledge"
  defp resolution_label(_incident), do: "Resolve"

  defp resolution_button_class(%{proposal_id: nil}), do: "admin-button button-warning"
  defp resolution_button_class(_incident), do: "admin-button button-primary"

  defp resolution_hint(%{proposal_id: nil}),
    do:
      "Acknowledges the alert only; the snapshot stays hidden — rotate the secret and push a new node."

  defp resolution_hint(_incident),
    do: "Re-scans the stored result; a remaining secret keeps this open — reject and re-propose."

  defp severity_row_class(:critical), do: "severity-critical"
  defp severity_row_class(:high), do: "severity-high"
  defp severity_row_class(_severity), do: nil

  defp kind_label(:secret_detected), do: "secret detected"
  defp kind_label(:scan_incomplete), do: "scan incomplete"
  defp kind_label(:meld_failed), do: "meld failed"
  defp kind_label(:agent_output_invalid), do: "agent output invalid"
  defp kind_label(:missing_objects), do: "missing objects"
  defp kind_label(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp kind_label(_kind), do: "incident"

  defp details_pairs(details) when is_map(details) do
    [
      {"patterns", patterns_value(Map.get(details, "patterns", Map.get(details, :patterns)))},
      {"sensitive paths",
       sensitive_paths_value(
         Map.get(details, "sensitive_paths", Map.get(details, :sensitive_paths))
       )},
      {"reason", reason_value(Map.get(details, "reason", Map.get(details, :reason)))}
    ]
    |> Enum.reject(fn {_label, value} -> is_nil(value) end)
  end

  defp details_pairs(_details), do: []

  defp patterns_value(patterns) when is_list(patterns) and patterns != [] do
    names =
      patterns
      |> Enum.filter(&(is_binary(&1) or is_atom(&1)))
      |> Enum.map(&to_string/1)
      |> Enum.take(5)

    if names == [], do: nil, else: Enum.join(names, ", ")
  end

  defp patterns_value(_patterns), do: nil

  defp sensitive_paths_value(count) when is_integer(count) and count > 0 do
    "#{count} sensitive #{if count == 1, do: "path", else: "paths"} hidden"
  end

  defp sensitive_paths_value(_count), do: nil

  defp reason_value(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp reason_value(reason) when is_atom(reason) and not is_nil(reason),
    do: Atom.to_string(reason)

  defp reason_value(_reason), do: nil
end
