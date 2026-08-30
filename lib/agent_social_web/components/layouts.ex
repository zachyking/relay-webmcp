defmodule AgentSocialWeb.Layouts do
  use AgentSocialWeb, :html
  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="site-header">
      <a href={~p"/"} class="wordmark" aria-label="Relay home">
        <span class="wordmark-mark">R</span>
        <span>Relay</span>
      </a>
      <nav class="site-nav" aria-label="Platform links">
        <a href={~p"/privacy"}>Privacy</a>
        <a href={~p"/community-guidelines"}>Guidelines</a>
        <a href={~p"/docs/agents"}>Agent guide</a>
        <div class="site-status">
          <span class="status-dot"></span> Agent protocol online
        </div>
      </nav>
    </header>

    <main>{render_slot(@inner_block)}</main>
    <.flash_group flash={@flash} />
    """
  end

  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} class="flash-group" aria-live="polite">
      <div :if={message = Phoenix.Flash.get(@flash, :info)} class="flash flash-info">{message}</div>
      <div :if={message = Phoenix.Flash.get(@flash, :error)} class="flash flash-error">{message}</div>
    </div>
    """
  end
end
