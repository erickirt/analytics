defmodule PlausibleWeb.CustomerSupport.Live.Team do
  @moduledoc false
  use Plausible.CustomerSupport.Resource, :component

  alias Plausible.Auth.SSO
  alias Plausible.Billing.EnterprisePlan
  alias Plausible.Billing.{Plans, Subscription}
  alias Plausible.Repo
  alias Plausible.Teams
  alias Plausible.Teams.Management.Layout
  alias PlausibleWeb.Router.Helpers, as: Routes

  require Plausible.Billing.Subscription.Status

  import Ecto.Query, only: [from: 2]

  def update(%{resource_id: resource_id}, socket) do
    team = Resource.Team.get(resource_id)
    changeset = Plausible.Teams.Team.crm_changeset(team, %{})
    form = to_form(changeset)

    usage = Teams.Billing.quota_usage(team, with_features: true)

    sso_integration = get_sso_integration(team)

    limits = %{
      monthly_pageviews: Teams.Billing.monthly_pageview_limit(team),
      sites: Teams.Billing.site_limit(team),
      team_members: Teams.Billing.team_member_limit(team)
    }

    {:ok,
     assign(socket,
       team: team,
       form: form,
       usage: usage,
       limits: limits,
       sso_integration: sso_integration
     )}
  end

  def update(%{tab: "sso"}, %{assigns: %{team: _team}} = socket) do
    {:ok, assign(socket, tab: "sso")}
  end

  def update(%{tab: "audit", tab_params: tab_params}, %{assigns: %{team: team}} = socket) do
    pagination_params = get_pagination_params(tab_params)

    audit_page = Plausible.Audit.list_entries_paginated([team_id: team.id], pagination_params)

    entries =
      Enum.map(audit_page.entries, fn entry ->
        meta = entry.meta

        meta =
          if entry.user_id && entry.user_id > 0 do
            user = Plausible.Repo.get(Plausible.Auth.User, entry.user_id)
            Map.put(meta, :user, user)
          else
            meta
          end

        meta =
          if entry.entity == "Plausible.Auth.User" do
            user = Plausible.Repo.get(Plausible.Auth.User, String.to_integer(entry.entity_id))
            Map.put(meta, :entity, user)
          else
            meta
          end

        Map.put(entry, :meta, meta)
      end)

    audit_page = %{audit_page | entries: entries}
    current_limit = pagination_params["limit"]

    {:ok,
     assign(socket,
       tab: "audit",
       audit_page: audit_page,
       revealed_audit_entry_id: nil,
       current_limit: current_limit
     )}
  end

  def update(%{tab: "sites"}, %{assigns: %{team: team}} = socket) do
    sites = Teams.owned_sites(team, 100)
    sites_count = Teams.owned_sites_count(team)

    {:ok, assign(socket, sites: sites, sites_count: sites_count, tab: "sites")}
  end

  def update(%{tab: "billing"}, %{assigns: %{team: team}} = socket) do
    plans = get_plans(team.id)

    plan =
      Plans.get_subscription_plan(team.subscription)

    attrs =
      if is_map(plan) do
        Map.take(plan, [
          :billing_interval,
          :monthly_pageview_limit,
          :site_limit,
          :team_member_limit,
          :hourly_api_request_limit,
          :features
        ])
        |> Map.update(:features, [], fn features ->
          Enum.map(features, &to_string(&1.name()))
        end)
      else
        %{
          monthly_pageview_limit: 10_000,
          hourly_api_request_limit: 600,
          site_limit: 10,
          team_member_limit: 10,
          features: Plausible.Billing.Feature.list() -- [Plausible.Billing.Feature.SSO]
        }
      end

    plan_form =
      to_form(
        EnterprisePlan.changeset(
          %EnterprisePlan{},
          attrs
        )
      )

    {:ok,
     assign(socket,
       plan: plan,
       plans: plans,
       plan_form: plan_form,
       show_plan_form?: false,
       editing_plan: nil,
       tab: "billing",
       cost_estimate: 0
     )}
  end

  def update(%{tab: "members"}, socket) do
    {:ok, refresh_members(socket)}
  end

  def update(_, socket) do
    {:ok, assign(socket, tab: "overview")}
  end

  attr :tab, :string, default: "overview"

  def render(assigns) do
    ~H"""
    <div>
      <script type="text/javascript">
        const featureChangeCallback = function(e) {
          const value = e.target.value
          const checked = e.target.checked
          const form = e.target.closest('form')

          if (value === 'sites_api' && checked) {
            form.querySelector('input[value=stats_api]').checked = true
          } else if (value === 'stats_api' && !checked) {
            form.querySelector('input[value=sites_api]').checked = false
          }
        }
      </script>
      <div class="overflow-hidden rounded-lg">
        <div class="p-6">
          <div class="sm:flex sm:items-center sm:justify-between">
            <div class="sm:flex sm:space-x-5">
              <div class="shrink-0">
                <div class={[
                  team_bg(@team.identifier),
                  "rounded-full p-1 flex items-center justify-center"
                ]}>
                  <Heroicons.user_group class="h-14 w-14 text-white dark:text-gray-300" />
                </div>
              </div>
              <div class="mt-4 text-center sm:mt-0 sm:pt-1 sm:text-left">
                <p class="text-xl font-bold dark:text-gray-300 text-gray-900 sm:text-2xl">
                  {@team.name}
                </p>
                <p class="text-sm font-medium">
                  <span :if={@team.setup_complete}>Set up at {@team.setup_at}</span>
                  <span :if={!@team.setup_complete}>Not set up yet</span>
                </p>
              </div>
            </div>

            <div class="mt-5 flex justify-center sm:mt-0">
              <.input_with_clipboard
                id="team-identifier"
                name="team-identifier"
                label="Team Identifier"
                value={@team.identifier}
                onfocus="this.value = this.value;"
              />
            </div>
          </div>
        </div>

        <div>
          <div class="hidden sm:block">
            <nav
              class="isolate flex divide-x dark:divide-gray-900 divide-gray-200 rounded-lg shadow dark:shadow-none"
              aria-label="Tabs"
            >
              <.tab to="overview" tab={@tab}>Overview</.tab>
              <.tab to="members" tab={@tab}>
                Members ({number_format(@usage.team_members)}/{number_format(@limits.team_members)})
              </.tab>
              <.tab to="sites" tab={@tab}>
                Sites ({number_format(@usage.sites)}/{number_format(@limits.sites)})
              </.tab>
              <.tab :if={@sso_integration} to="sso" tab={@tab}>
                SSO
              </.tab>
              <.tab to="billing" tab={@tab}>
                Billing
              </.tab>
              <.tab to="audit" tab={@tab}>
                Audit
              </.tab>
            </nav>
          </div>
        </div>

        <div class="grid grid-cols-1 divide-y border-t sm:grid-cols-3 sm:divide-x sm:divide-y-0 dark:bg-gray-850 text-gray-900 dark:text-gray-400 dark:divide-gray-800 dark:border-gray-600">
          <div class="px-6 py-5 text-center text-sm font-medium">
            <span>
              <strong>Subscription status</strong> <br />{subscription_status(@team)}
              <div :if={
                @team.subscription && @team.subscription.status == Subscription.Status.deleted() &&
                  !@team.grace_period
              }>
                <span class="flex items-center gap-x-8 justify-center mt-1">
                  <div :if={not Teams.locked?(@team)}>
                    <Heroicons.lock_open solid class="inline stroke-2 w-4 h-4 text-red-400 mr-1" />
                    <.styled_link
                      phx-click="refund-lock"
                      phx-target={@myself}
                      data-confirm="Are you sure you want to lock? The only way to unlock, is for the user to resubscribe."
                    >
                      Refund Lock
                    </.styled_link>
                  </div>

                  <div :if={Teams.locked?(@team)}>
                    <Heroicons.lock_closed solid class="inline stroke-2 w-4 h-4 text-red-400 mr-1" />
                    Locked
                  </div>
                </span>
              </div>
            </span>
          </div>
          <div class="px-6 py-5 text-center text-sm font-medium">
            <span>
              <strong>Subscription plan</strong> <br />{subscription_plan(@team)}
            </span>
          </div>
          <div class="px-6 py-5 text-center text-sm font-medium">
            <span>
              <strong>Grace Period</strong> <br />{grace_period_status(@team)}

              <div :if={@team.grace_period}>
                <span class="flex items-center gap-x-8 justify-center mt-1">
                  <div>
                    <Heroicons.lock_open solid class="inline stroke-2 w-4 h-4 text-red-400 mr-1" />
                    <.styled_link phx-click="unlock" phx-target={@myself}>Unlock</.styled_link>
                  </div>

                  <div>
                    <Heroicons.lock_closed solid class="inline stroke-2 w-4 h-4 text-red-400 mr-1" />
                    <.styled_link phx-click="lock" phx-target={@myself}>Lock</.styled_link>
                  </div>
                </span>
              </div>
            </span>
          </div>
        </div>

        <div :if={@tab == "sso"} class="mt-4 mb-4 text-gray-900 dark:text-gray-400">
          <div :if={@sso_integration} class="flex gap-x-8 mb-4 justify-between items-start">
            <p>
              Configured?: <code>{SSO.Integration.configured?(@sso_integration)}</code>
              <br /> IDP Signin URL:
              <code>
                {@sso_integration.config.idp_signin_url}
              </code>
              <br />IDP Entity ID: <code>{@sso_integration.config.idp_entity_id}</code>
            </p>
            <div class="ml-auto">
              <.button
                data-confirm="Are you sure you want to remove this SSO team integration, including all its domains and users?"
                id="remove-sso-integration"
                phx-click="remove-sso-integration"
                phx-target={@myself}
                theme="danger"
              >
                Remove Integration
              </.button>
            </div>
          </div>
          <.table rows={@sso_integration.sso_domains}>
            <:thead>
              <.th>Domain</.th>
              <.th>Status</.th>
              <.th></.th>
            </:thead>
            <:tbody :let={sso_domain}>
              <.td>
                {sso_domain.domain}
              </.td>
              <.td>
                {sso_domain.status}
                <span :if={sso_domain.verified_via}>
                  (via {sso_domain.verified_via} at {Calendar.strftime(
                    sso_domain.last_verified_at,
                    "%b %-d, %Y"
                  )})
                </span>
              </.td>
              <.td actions>
                <.delete_button
                  id={"remove-sso-domain-#{sso_domain.identifier}"}
                  phx-click="remove-sso-domain"
                  phx-value-identifier={sso_domain.identifier}
                  phx-target={@myself}
                  class="text-sm text-red-600"
                  data-confirm={"Are you sure you want to remove domain '#{sso_domain.domain}'? All SSO users will be deprovisioned and logged out."}
                />
              </.td>
            </:tbody>
          </.table>
        </div>

        <div :if={@tab == "audit"} class="mt-4 mb-4 text-gray-900 dark:text-gray-400 relative">
          <div :if={Enum.empty?(@audit_page.entries)} class="flex justify-center items-center">
            No audit logs yet
          </div>
          <div
            :if={@revealed_audit_entry_id}
            phx-target={@myself}
            phx-window-keydown="reveal-audit-entry"
            phx-key="escape"
          >
            <.input_with_clipboard
              id="audit-entry-identifier"
              name="audit-entry-identifier"
              label="Audit Entry Identifier"
              value={@revealed_audit_entry_id}
            />
            <div class="relative">
              <.input
                rows="16"
                type="textarea"
                id="audit-entry-change"
                name="audit-entry-change"
                value={
                  Jason.encode!(
                    Enum.find(@audit_page.entries, &(&1.id == @revealed_audit_entry_id)).change,
                    pretty: true
                  )
                }
              >
              </.input>
              <.styled_link
                class="text-sm float-right"
                onclick="var textarea = document.getElementById('audit-entry-change'); textarea.focus(); textarea.select(); document.execCommand('copy');"
                href="#"
              >
                <div class="flex items-center absolute top-4 right-4 text-xs gap-x-1">
                  <Heroicons.document_duplicate class="h-4 w-4 text-indigo-700" /> COPY
                </div>
              </.styled_link>

              <.styled_link
                phx-click="reveal-audit-entry"
                phx-target={@myself}
                class="float-right pt-4 text-sm"
              >
                &larr; Return
                <kbd class="rounded border border-gray-200 dark:border-gray-600 px-2 font-mono font-normal text-xs text-gray-400">
                  ESC
                </kbd>
              </.styled_link>
            </div>
          </div>
          <.table :if={is_nil(@revealed_audit_entry_id)} rows={@audit_page.entries}>
            <:thead>
              <.th invisible></.th>
              <.th invisible></.th>
              <.th>Name</.th>
              <.th>Entity</.th>
              <.th>Actor</.th>
              <.th invisible>Actions</.th>
            </:thead>
            <:tbody :let={entry}>
              <.td>{Calendar.strftime(entry.datetime, "%Y-%m-%d")}</.td>
              <.td>{Calendar.strftime(entry.datetime, "%H:%M:%S")}</.td>
              <.td class="font-mono">{entry.name}</.td>
              <.td truncate>
                <.audit_entity entry={entry} />
              </.td>
              <.td :if={entry.actor_type == :system}>
                <div class="flex items-center gap-x-1">
                  <Heroicons.cog_6_tooth class="size-4" /> SYSTEM
                </div>
              </.td>
              <.td :if={entry.actor_type == :user} truncate>
                <.audit_user user={entry.meta.user} />
              </.td>

              <.td actions>
                <.edit_button
                  phx-click="reveal-audit-entry"
                  icon={:magnifying_glass_plus}
                  phx-value-id={entry.id}
                  phx-target={@myself}
                />
              </.td>
            </:tbody>
          </.table>
          <div
            :if={
              is_nil(@revealed_audit_entry_id) &&
                (@audit_page.metadata.before || @audit_page.metadata.after)
            }
            class="flex justify-between items-center mt-4"
          >
            <.button
              :if={@audit_page.metadata.before}
              id="prev-page"
              phx-click="paginate-audit"
              phx-value-before={@audit_page.metadata.before}
              phx-value-limit={@current_limit}
              phx-target={@myself}
              theme="bright"
            >
              &larr; Prev
            </.button>
            <div></div>
            <.button
              :if={@audit_page.metadata.after}
              id="next-page"
              phx-click="paginate-audit"
              phx-value-after={@audit_page.metadata.after}
              phx-value-limit={@current_limit}
              phx-target={@myself}
              theme="bright"
            >
              Next &rarr;
            </.button>
          </div>
        </div>
        <div :if={@tab == "billing"} class="mt-4 mb-4 text-gray-900 dark:text-gray-400">
          <h1 class="text-xs font-semibold">Usage</h1>
          <.table rows={monthly_pageviews_usage(@usage.monthly_pageviews, @limits.monthly_pageviews)}>
            <:thead>
              <.th invisible>Cycle</.th>
              <.th invisible>Dates</.th>
              <.th>Total</.th>
              <.th>Limit</.th>
            </:thead>
            <:tbody :let={{cycle, date, total, limit}}>
              <.td>{cycle}</.td>
              <.td>{date}</.td>
              <.td>
                <span class={if total > limit, do: "text-red-600"}>{number_format(total)}</span>
              </.td>
              <.td>{number_format(limit)}</.td>
            </:tbody>
          </.table>

          <p :if={@usage.features != []} class="mt-6 mb-4">
            <h1 class="text-xs font-semibold">Features Used</h1>
            <span class="text-sm">
              {@usage.features |> Enum.map(& &1.display_name()) |> Enum.join(", ")}
            </span>
          </p>

          <h1 :if={!@show_plan_form? and @plans != []} class="mt-8 text-xs font-semibold">
            Custom Plans
          </h1>
          <.table :if={!@show_plan_form?} rows={@plans}>
            <:thead>
              <.th invisible>Interval</.th>
              <.th>Paddle Plan ID</.th>
              <.th>Limits</.th>
              <.th>Features</.th>
              <.th invisible>Actions</.th>
            </:thead>
            <:tbody :let={plan}>
              <.td class="align-top">
                {plan.billing_interval}
              </.td>
              <.td class="align-top">
                {plan.paddle_plan_id}

                <span
                  :if={
                    (@team.subscription && @team.subscription.paddle_plan_id) == plan.paddle_plan_id
                  }
                  class="inline-flex items-center px-2 py-0.5 rounded text-xs font-xs bg-red-100 text-red-800"
                >
                  CURRENT
                </span>
              </.td>
              <.td max_width="max-w-40">
                <.table rows={[
                  {"Pageviews", number_format(plan.monthly_pageview_limit)},
                  {"Sites", number_format(plan.site_limit)},
                  {"Members", number_format(plan.team_member_limit)},
                  {"API Requests", number_format(plan.hourly_api_request_limit)}
                ]}>
                  <:tbody :let={{label, value}}>
                    <.td>{label}</.td>
                    <.td>{value}</.td>
                  </:tbody>
                </.table>
              </.td>
              <.td class="align-top">
                <span :for={feat <- plan.features}>{feat.display_name()}<br /></span>
              </.td>
              <.td class="align-top">
                <.edit_button phx-click="edit-plan" phx-value-id={plan.id} phx-target={@myself} />
              </.td>
            </:tbody>
          </.table>

          <.form
            :let={f}
            :if={@show_plan_form?}
            for={@plan_form}
            id="save-plan"
            phx-submit={if @editing_plan, do: "update-plan", else: "save-plan"}
            phx-target={@myself}
            phx-change="estimate-cost"
          >
            <.input field={f[:paddle_plan_id]} label="Paddle Plan ID" autocomplete="off" />
            <.input
              type="select"
              options={["monthly", "yearly"]}
              field={f[:billing_interval]}
              label="Billing Interval"
              autocomplete="off"
            />

            <div class="flex items-center gap-x-4">
              <.input
                field={f[:monthly_pageview_limit]}
                label="Monthly Pageview Limit"
                autocomplete="off"
                width="w-[500]"
              />

              <.preview for={f[:monthly_pageview_limit]} />
            </div>
            <div class="flex items-center gap-x-4">
              <.input width="w-[500]" field={f[:site_limit]} label="Site Limit" autocomplete="off" />

              <.preview for={f[:site_limit]} />
            </div>

            <div class="flex items-center gap-x-4">
              <.input
                field={f[:team_member_limit]}
                label="Team Member Limit"
                autocomplete="off"
                width="w-[500]"
              />

              <.preview for={f[:team_member_limit]} />
            </div>

            <div class="flex items-center gap-x-4">
              <.input
                field={f[:hourly_api_request_limit]}
                label="Hourly API Request Limit"
                autocomplete="off"
                width="w-[500]"
              />

              <.preview for={f[:hourly_api_request_limit]} />
            </div>

            <.input
              :for={
                mod <-
                  Plausible.Billing.Feature.list()
                  |> Enum.sort_by(fn item -> if item.name() == :stats_api, do: 0, else: 1 end)
              }
              :if={not mod.free?()}
              x-on:change="featureChangeCallback(event)"
              type="checkbox"
              value={mod in (f.source.changes[:features] || f.source.data.features || [])}
              name={"#{f.name}[features[]][#{mod.name()}]"}
              label={mod.display_name()}
            />

            <div class="mt-8 flex align-center gap-x-4">
              <.input_with_clipboard
                id="cost-estimate"
                name="cost-estimate"
                label={"#{(f[:billing_interval].value || "monthly")} cost estimate"}
                value={@cost_estimate}
              />

              <.button theme="bright" phx-click="hide-plan-form" phx-target={@myself}>
                Cancel
              </.button>

              <.button type="submit">
                {if @editing_plan, do: "Update Plan", else: "Save Custom Plan"}
              </.button>
            </div>
          </.form>

          <.button
            :if={!@show_plan_form?}
            id="new-custom-plan"
            phx-click="show-plan-form"
            phx-target={@myself}
          >
            New Custom Plan
          </.button>
        </div>

        <div :if={@tab == "overview"} class="mt-8">
          <.form :let={f} for={@form} phx-submit="save-team" phx-target={@myself}>
            <.input field={f[:trial_expiry_date]} type="date" label="Trial Expiry Date" />
            <.input field={f[:accept_traffic_until]} type="date" label="Accept  traffic Until" />
            <.input
              type="checkbox"
              field={f[:allow_next_upgrade_override]}
              label="Allow Next Upgrade Override"
            />

            <.input type="textarea" field={f[:notes]} label="Notes" />

            <div class="flex justify-between">
              <.button type="submit">
                Save
              </.button>

              <.button
                phx-target={@myself}
                phx-click="delete-team"
                data-confirm="Are you sure you want to delete this team?"
                theme="danger"
              >
                Delete Team
              </.button>
            </div>
          </.form>
        </div>

        <div :if={@tab == "sites"} class="mt-2">
          <.notice :if={@sites_count > 100} class="mt-4 mb-4">
            This team owns more than 100 sites. Displaying first 100 below.
          </.notice>
          <.table rows={@sites}>
            <:thead>
              <.th>Domain</.th>
              <.th>Previous Domain</.th>
              <.th>Timezone</.th>
              <.th invisible>Settings</.th>
              <.th invisible>Dashboard</.th>
            </:thead>
            <:tbody :let={site}>
              <.td>
                <div class="flex items-center">
                  <img
                    src="/favicon/sources/{site.domain}"
                    onerror="this.onerror=null; this.src='/favicon/sources/placeholder';"
                    class="w-4 h-4 flex-shrink-0 mt-px mr-2"
                  />
                  <.styled_link
                    patch={"/cs/sites/site/#{site.id}"}
                    class="cursor-pointer flex block items-center"
                  >
                    {site.domain}
                  </.styled_link>
                </div>
              </.td>
              <.td>{site.domain_changed_from || "--"}</.td>
              <.td>{site.timezone}</.td>
              <.td>
                <.styled_link
                  new_tab={true}
                  href={Routes.stats_path(PlausibleWeb.Endpoint, :stats, site.domain, [])}
                >
                  Dashboard
                </.styled_link>
              </.td>
              <.td>
                <.styled_link
                  new_tab={true}
                  href={Routes.site_path(PlausibleWeb.Endpoint, :settings_general, site.domain, [])}
                >
                  Settings
                </.styled_link>
              </.td>
            </:tbody>
          </.table>
        </div>

        <div :if={@tab == "members"} class="mt-2">
          <.table rows={Layout.sorted_for_display(@team_layout)}>
            <:thead>
              <.th>User</.th>
              <.th>Sessions</.th>
              <.th>Type</.th>
              <.th>Role</.th>
            </:thead>
            <:tbody :let={{_, member}}>
              <.td truncate>
                <div :if={member.id != 0}>
                  <.styled_link
                    patch={"/cs/users/user/#{member.id}"}
                    class="cursor-pointer flex block items-center"
                  >
                    <img
                      src={
                        Plausible.Auth.User.profile_img_url(%Plausible.Auth.User{email: member.email})
                      }
                      class="mr-4 w-6 rounded-full bg-gray-300"
                    />
                    {member.name} &lt;{member.email}&gt;
                  </.styled_link>
                </div>
                <div :if={member.id == 0} class="flex items-center">
                  <img
                    src={
                      Plausible.Auth.User.profile_img_url(%Plausible.Auth.User{email: member.email})
                    }
                    class="mr-4 w-6 rounded-full bg-gray-300"
                  />
                  {member.name} &lt;{member.email}&gt;
                </div>
              </.td>
              <.td>
                {@session_counts[member.meta.user.id] || 0}
              </.td>
              <.td>
                <div class="flex items-center gap-x-1">
                  <span :if={member.meta.user.type == :sso}>SSO </span>{member.type}

                  <.delete_button
                    :if={member.meta.user.type == :sso}
                    id={"deprovision-sso-user-#{member.id}"}
                    phx-click="deprovision-sso-user"
                    phx-value-identifier={member.id}
                    phx-target={@myself}
                    class="text-sm"
                    icon={:user_minus}
                    data-confirm="Are you sure you want to deprovision SSO user and convert them to a standard user? This will sign them out and force to use regular e-mail/password combination to log in again."
                  />
                </div>
              </.td>
              <.td>
                {member.role}
              </.td>
            </:tbody>
          </.table>
        </div>
      </div>
    </div>
    """
  end

  def render_result(assigns) do
    ~H"""
    <div class="flex-1 -mt-px w-full">
      <div class="w-full flex items-center justify-between space-x-4">
        <div class={[
          team_bg(@resource.object.identifier),
          "rounded-full p-1 flex items-center justify-center"
        ]}>
          <Heroicons.user_group class="h-4 w-4 text-white" />
        </div>
        <h3
          class="text-gray-900 font-medium text-lg truncate dark:text-gray-100"
          style="width: calc(100% - 4rem)"
        >
          {@resource.object.name}
        </h3>

        <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-blue-100 text-blue-800">
          Team
        </span>

        <span
          :if={@resource.object.subscription}
          class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800"
        >
          $
        </span>
      </div>

      <hr class="mt-4 mb-4 flex-grow border-t border-gray-200 dark:border-gray-600" />
      <div class="text-sm truncate">
        Team identifier:
        <code class="font-mono">{@resource.object.identifier |> String.slice(0, 8)}</code>
        <br />
        Owned by: {@resource.object.owners
        |> Enum.map(& &1.name)
        |> Enum.join(", ")}
      </div>
    </div>
    """
  end

  def handle_event("reveal-audit-entry", %{"id" => id}, socket) do
    {:noreply, assign(socket, revealed_audit_entry_id: id)}
  end

  def handle_event("reveal-audit-entry", _, socket) do
    {:noreply, assign(socket, revealed_audit_entry_id: nil)}
  end

  def handle_event("paginate-audit", params, socket) do
    pagination_params = get_pagination_params(params)
    team = socket.assigns.team

    query_params = %{"tab" => "audit"} |> Map.merge(pagination_params)

    {:noreply,
     push_patch(socket,
       to: "/cs/teams/team/#{team.id}?" <> URI.encode_query(query_params)
     )}
  end

  def handle_event("show-plan-form", _, socket) do
    {:noreply, assign(socket, show_plan_form?: true, editing_plan: nil)}
  end

  def handle_event("edit-plan", %{"id" => plan_id}, socket) do
    {plan_id, _} = Integer.parse(plan_id)
    plan = Enum.find(socket.assigns.plans, &(&1.id == plan_id))

    if plan do
      plan_form = to_form(EnterprisePlan.changeset(plan, %{}))

      {:noreply, assign(socket, show_plan_form?: true, editing_plan: plan, plan_form: plan_form)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove-sso-integration", _, socket) do
    :ok = SSO.remove_integration(socket.assigns.sso_integration, force_deprovision?: true)

    socket =
      socket
      |> assign(sso_integration: nil)
      |> put_flash(:success, "SSO integration removed")
      |> refresh_members()
      |> push_navigate(
        to:
          Routes.customer_support_resource_path(
            socket,
            :details,
            :teams,
            :team,
            socket.assigns.team.id
          )
      )

    {:noreply, socket}
  end

  def handle_event("remove-sso-domain", %{"identifier" => i}, socket) do
    domain = Enum.find(socket.assigns.sso_integration.sso_domains, &(&1.identifier == i))
    :ok = SSO.Domains.remove(domain, force_deprovision?: true)
    socket = socket |> success("SSO domain removed") |> refresh_members()
    {:noreply, assign(socket, sso_integration: get_sso_integration(socket.assigns.team))}
  end

  def handle_event("hide-plan-form", _, socket) do
    {:noreply, assign(socket, show_plan_form?: false, editing_plan: nil)}
  end

  def handle_event("save-team", %{"team" => params}, socket) do
    changeset = Plausible.Teams.Team.crm_changeset(socket.assigns.team, params)

    case Plausible.Repo.update(changeset) do
      {:ok, team} ->
        success(socket, "Team saved")
        {:noreply, assign(socket, team: team, form: to_form(changeset))}

      {:error, changeset} ->
        failure(socket, "Error saving team: #{inspect(changeset.errors)}")
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("delete-team", _params, socket) do
    case Teams.delete(socket.assigns.team) do
      {:ok, :deleted} ->
        {:noreply, push_navigate(put_flash(socket, :success, "Team deleted"), to: "/cs")}

      {:error, :active_subscription} ->
        failure(
          socket,
          "The team has an active subscription which must be canceled first."
        )

        {:noreply, socket}
    end
  end

  def handle_event("deprovision-sso-user", %{"identifier" => user_id}, socket) do
    [id: String.to_integer(user_id)]
    |> Plausible.Auth.find_user_by()
    |> SSO.deprovision_user!()

    socket = socket |> success("SSO user deprovisioned") |> refresh_members()
    {:noreply, socket}
  end

  def handle_event("estimate-cost", %{"enterprise_plan" => params}, socket) do
    params = update_features_to_list(params)

    form =
      to_form(
        EnterprisePlan.changeset(
          %EnterprisePlan{},
          params
        )
      )

    params = sanitize_params(params)

    cost_estimate =
      Plausible.CustomerSupport.EnterprisePlan.estimate(
        params["billing_interval"],
        get_int_param(params, "monthly_pageview_limit"),
        get_int_param(params, "site_limit"),
        get_int_param(params, "team_member_limit"),
        get_int_param(params, "hourly_api_request_limit"),
        params["features"]
      )

    socket =
      assign(socket,
        cost_estimate: cost_estimate,
        plan_form: form
      )

    {:noreply, socket}
  end

  def handle_event("save-plan", %{"enterprise_plan" => params}, socket) do
    params =
      params
      |> update_features_to_list()
      |> sanitize_params()

    changeset = EnterprisePlan.changeset(%EnterprisePlan{team_id: socket.assigns.team.id}, params)

    case Plausible.Repo.insert(changeset) do
      {:ok, _plan} ->
        success(socket, "Plan saved")
        plans = get_plans(socket.assigns.team.id)

        {:noreply,
         assign(socket,
           plans: plans,
           plan_form: to_form(changeset),
           show_plan_form?: false,
           editing_plan: nil
         )}

      {:error, changeset} ->
        failure(socket, "Error saving plan: #{inspect(changeset.errors)}")
        {:noreply, assign(socket, plan_form: to_form(changeset))}
    end
  end

  def handle_event("update-plan", %{"enterprise_plan" => params}, socket) do
    params =
      params
      |> update_features_to_list()
      |> sanitize_params()

    changeset = EnterprisePlan.changeset(socket.assigns.editing_plan, params)

    case Plausible.Repo.update(changeset) do
      {:ok, _plan} ->
        success(socket, "Plan updated")
        plans = get_plans(socket.assigns.team.id)

        {:noreply,
         assign(socket,
           plans: plans,
           plan_form: to_form(changeset),
           show_plan_form?: false,
           editing_plan: nil
         )}

      {:error, changeset} ->
        failure(socket, "Error updating plan: #{inspect(changeset.errors)}")
        {:noreply, assign(socket, plan_form: to_form(changeset))}
    end
  end

  def handle_event("unlock", _, socket) do
    {:noreply, unlock_team(socket)}
  end

  def handle_event("lock", _, socket) do
    {:noreply, lock_team(socket)}
  end

  def handle_event("refund-lock", _, socket) do
    team = socket.assigns.team

    {:ok, team} =
      Repo.transaction(fn ->
        yesterday = Date.shift(Date.utc_today(), day: -1)
        Plausible.Billing.SiteLocker.set_lock_status_for(team, true)
        Repo.update!(Subscription.changeset(team.subscription, %{next_bill_date: yesterday}))
        Resource.Team.get(team.id)
      end)

    {:noreply, assign(socket, team: team)}
  end

  def team_bg(term) do
    list = [
      "bg-blue-500",
      "bg-blue-600",
      "bg-blue-700",
      "bg-blue-800",
      "bg-cyan-500",
      "bg-cyan-600",
      "bg-cyan-700",
      "bg-cyan-800",
      "bg-red-500",
      "bg-red-600",
      "bg-red-700",
      "bg-red-800",
      "bg-green-500",
      "bg-green-600",
      "bg-green-700",
      "bg-green-800",
      "bg-yellow-500",
      "bg-yellow-600",
      "bg-yellow-700",
      "bg-yellow-800",
      "bg-orange-500",
      "bg-orange-600",
      "bg-orange-700",
      "bg-orange-800",
      "bg-purple-500",
      "bg-purple-600",
      "bg-purple-700",
      "bg-purple-800",
      "bg-gray-500",
      "bg-gray-600",
      "bg-gray-700",
      "bg-gray-800",
      "bg-emerald-500",
      "bg-emerald-600",
      "bg-emerald-700",
      "bg-emerald-800"
    ]

    idx = :erlang.phash2(term, length(list))
    Enum.at(list, idx)
  end

  def subscription_status(team) do
    cond do
      team && team.subscription ->
        status_str =
          PlausibleWeb.SettingsView.present_subscription_status(team.subscription.status)

        if team.subscription.paddle_subscription_id do
          assigns = %{status_str: status_str, subscription: team.subscription}

          ~H"""
          <.styled_link new_tab={true} href={manage_url(@subscription)}>{@status_str}</.styled_link>
          """
        else
          status_str
        end

      Plausible.Teams.on_trial?(team) ->
        "On trial"

      true ->
        "Trial expired"
    end
  end

  defp manage_url(%{paddle_subscription_id: paddle_id} = _subscription) do
    Plausible.Billing.PaddleApi.vendors_domain() <>
      "/subscriptions/customers/manage/" <> paddle_id
  end

  def subscription_plan(team) do
    subscription = team.subscription

    if Subscription.Status.active?(subscription) && subscription.paddle_subscription_id do
      quota = PlausibleWeb.AuthView.subscription_quota(subscription)
      interval = PlausibleWeb.AuthView.subscription_interval(subscription)

      assigns = %{quota: quota, interval: interval, subscription: subscription}

      ~H"""
      <.styled_link new_tab={true} href={manage_url(@subscription)}>
        {@quota} ({@interval})
      </.styled_link>
      """
    else
      "--"
    end
  end

  def grace_period_status(team) do
    grace_period = team.grace_period

    case grace_period do
      nil ->
        "--"

      %{manual_lock: true, is_over: true} ->
        "Manually locked"

      %{manual_lock: true, is_over: false} ->
        "Waiting for manual lock"

      %{is_over: true} ->
        "ended"

      %{end_date: %Date{} = end_date} ->
        days_left = Date.diff(end_date, Date.utc_today())
        "#{days_left} days left"
    end
  end

  defp lock_team(socket) do
    if socket.assigns.team.grace_period do
      team = Plausible.Teams.end_grace_period(socket.assigns.team)
      Plausible.Billing.SiteLocker.set_lock_status_for(team, true)

      success(socket, "Team locked. Grace period ended.")
      assign(socket, team: team)
    else
      failure(socket, "No grace period")
      socket
    end
  end

  defp unlock_team(socket) do
    if socket.assigns.team.grace_period do
      team = Plausible.Teams.remove_grace_period(socket.assigns.team)
      Plausible.Billing.SiteLocker.set_lock_status_for(team, false)

      success(socket, "Team unlocked. Grace period removed.")
      assign(socket, team: team)
    else
      socket
    end
  end

  defp monthly_pageviews_usage(usage, limit) do
    usage
    |> Enum.sort_by(fn {_cycle, usage} -> usage.date_range.first end, :desc)
    |> Enum.map(fn {cycle, usage} ->
      {cycle, PlausibleWeb.TextHelpers.format_date_range(usage.date_range), usage.total, limit}
    end)
  end

  defp get_plans(team_id) do
    Repo.all(
      from ep in EnterprisePlan,
        where: ep.team_id == ^team_id,
        order_by: [desc: :id]
    )
  end

  defp number_format(unlimited) when unlimited in [-1, "unlimited", :unlimited] do
    "unlimited"
  end

  defp number_format(number) when is_integer(number) do
    Cldr.Number.to_string!(number)
  end

  defp number_format(other), do: other

  defp sanitize_params(params) do
    params
    |> Enum.map(&clear_param/1)
    |> Enum.reject(&(&1 == ""))
    |> Map.new()
  end

  defp clear_param({key, value}) when is_binary(value) do
    {key, String.trim(value)}
  end

  defp clear_param(other) do
    other
  end

  defp get_int_param(params, key) do
    param = Map.get(params, key)
    param = if param in ["", nil], do: "0", else: param

    case Integer.parse(param) do
      {integer, ""} -> integer
      _ -> 0
    end
  end

  defp update_features_to_list(params) do
    features =
      params["features[]"]
      |> Enum.reject(fn {_key, value} -> value == "false" or value == "" end)
      |> Enum.map(fn {key, _value} -> key end)

    Map.put(params, "features", features)
  end

  defp preview_number(n) do
    case Integer.parse("#{n}") do
      {n, ""} ->
        number_format(n) <> " (#{PlausibleWeb.StatsView.large_number_format(n)})"

      _ ->
        "0"
    end
  end

  attr :for, :any, required: true

  defp preview(assigns) do
    ~H"""
    <.input
      name={"#{@for.name}-preview"}
      label="Preview"
      autocomplete="off"
      width="w-[500]"
      readonly
      value={preview_number(@for.value)}
      class="bg-transparent border-0 p-0 m-0 text-sm w-full"
    />
    """
  end

  defp get_sso_integration(team) do
    case SSO.get_integration_for(team) do
      {:error, :not_found} -> nil
      {:ok, integration} -> integration
    end
  end

  defp refresh_members(socket) do
    team_layout = Layout.init(socket.assigns.team)

    session_counts =
      team_layout
      |> Enum.map(fn {_, entry} -> entry.meta.user end)
      |> Plausible.Auth.UserSessions.count_for_users()
      |> Enum.into(%{})

    assign(socket, team_layout: team_layout, session_counts: session_counts, tab: "members")
  end

  attr :entry, Plausible.Audit.Entry

  defp audit_entity(assigns) do
    ~H"""
    <%= if @entry.entity == "Plausible.Auth.User" do %>
      <.audit_user user={@entry.meta.entity} />
    <% else %>
      {@entry.entity |> String.split(".") |> List.last()} #{String.slice(@entry.entity_id, 0, 8)}
    <% end %>
    """
  end

  attr :user, Plausible.Auth.User

  defp audit_user(%{user: nil} = assigns) do
    ~H"""
    (N/A)
    """
  end

  defp audit_user(assigns) do
    ~H"""
    <div class="flex items-center gap-x-1">
      <img
        class="w-4"
        src={
          Plausible.Auth.User.profile_img_url(%Plausible.Auth.User{
            email: @user.email
          })
        }
      />

      <.styled_link
        patch={"/cs/users/user/#{@user.id}"}
        class="cursor-pointer flex block items-center"
      >
        {@user.name}
      </.styled_link>
    </div>
    """
  end

  defp get_pagination_params(params) do
    params
    |> Map.take(["after", "before", "limit"])
    |> Map.put_new("limit", 15)
  end
end
