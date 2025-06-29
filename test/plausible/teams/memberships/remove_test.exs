defmodule Plausible.Teams.Memberships.RemoveTest do
  use Plausible.DataCase, async: true
  use Plausible
  use Plausible.Repo
  use Plausible.Teams.Test
  use Bamboo.Test

  alias Plausible.Teams.Memberships.Remove

  @subject_prefix if ee?(), do: "[Plausible Analytics] ", else: "[Plausible CE] "

  test "removes a member from a team" do
    user = new_user()
    _site = new_site(owner: user)
    team = team_of(user)
    collaborator = add_member(team, role: :editor)
    assert_team_membership(collaborator, team, :editor)

    assert {:ok, _} = Remove.remove(team, collaborator.id, user)

    refute_team_member(collaborator, team)

    assert_email_delivered_with(
      to: [nil: collaborator.email],
      subject: @subject_prefix <> "Your access to \"#{team.name}\" team has been revoked"
    )

    assert Repo.reload(user)
  end

  test "when member is removed, associated personal segment is deleted" do
    user = new_user()
    site = new_site(owner: user)
    team = team_of(user)
    collaborator = add_member(team, role: :editor)

    segment =
      insert(:segment,
        type: :personal,
        owner: collaborator,
        site: site,
        name: "personal segment"
      )

    assert {:ok, _} = Remove.remove(team, collaborator.id, user)

    refute Repo.reload(segment)
  end

  test "when member is removed, associated site segment will be owner-less" do
    user = new_user()
    site = new_site(owner: user)
    team = team_of(user)
    collaborator = add_member(team, role: :editor)

    segment =
      insert(:segment,
        type: :site,
        owner: collaborator,
        site: site,
        name: "site segment"
      )

    assert {:ok, _} = Remove.remove(team, collaborator.id, user)

    assert Repo.reload(segment).owner_id == nil
  end

  test "can't remove the only owner" do
    user = new_user()
    _site = new_site(owner: user)
    team = team_of(user)

    assert {:error, :only_one_owner} = Remove.remove(team, user.id, user)

    assert_team_membership(user, team, :owner)
  end

  test "can remove self (the owner) when there's more than one owner" do
    user = new_user()
    _site = new_site(owner: user)
    team = team_of(user)
    _another_owner = add_member(team, role: :owner)

    assert {:ok, _} = Remove.remove(team, user.id, user)

    refute_team_member(user, team)
  end

  test "can remove another owner when there's more than one owner" do
    user = new_user()
    _site = new_site(owner: user)
    team = team_of(user)
    another_owner = add_member(team, role: :owner)

    assert {:ok, _} = Remove.remove(team, another_owner.id, user)

    refute_team_member(another_owner, team)
  end

  test "admin can't remove owner" do
    user = new_user()
    owner = new_user()
    _site = new_site(owner: owner)
    team = team_of(owner)
    _another_owner = add_member(team, role: :owner)
    _admin = add_member(team, user: user, role: :admin)

    assert {:error, :permission_denied} = Remove.remove(team, owner.id, user)

    assert_team_membership(owner, team, :owner)
  end

  for role <- Plausible.Teams.Membership.roles() -- [:owner, :admin] do
    test "#{role} can't update role of a member" do
      user = new_user()
      owner = new_user()
      _site = new_site(owner: owner)
      team = team_of(owner)
      _member = add_member(team, user: user, role: unquote(role))
      another_member = add_member(team, role: :viewer)

      assert {:error, :permission_denied} = Remove.remove(team, another_member.id, user)

      assert_team_membership(another_member, team, :viewer)
    end
  end

  on_ee do
    describe "SSO user" do
      setup [:create_user, :create_team, :setup_sso, :provision_sso_user]

      test "removes SSO user along with membership", %{team: team, user: user} do
        owner = add_member(team, role: :owner)

        assert {:ok, _} = Remove.remove(team, user.id, owner)

        refute_team_member(user, team)

        assert_email_delivered_with(
          to: [nil: user.email],
          subject: @subject_prefix <> "Your access to \"#{team.name}\" team has been revoked"
        )

        refute Repo.reload(user)
      end
    end
  end
end
