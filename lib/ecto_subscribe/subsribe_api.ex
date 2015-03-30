defmodule Ecto.Subscribe.Api do

  import Ecto.Query
  import Ecto.Model.Callbacks

  @doc """
  """
  def subscribe(repo, model, opts) do
    repo.insert(%Ecto.Subscribe.Schema.SystemTable{model: (model |> Macro.to_string),
                                                   subscription_info: "all",
                                                   subscription_actions: "all",
                                                   adapter: get_opts_field(opts, :adapter),
                                                   receiver: get_opts_field(opts, :receiver)})
    :ok
  end

  def subscribe(repo, model, subscription_data, opts) do
    repo.insert(%Ecto.Subscribe.Schema.SystemTable{model: (model |> Macro.to_string),
                                                   subscription_info: subscription_data,
                                                   subscription_actions: actions_to_string(get_actions(get_opts_field(opts, :actions))),
                                                   adapter: get_opts_field(opts, :adapter),
                                                   receiver: get_opts_field(opts, :receiver)})
    :ok
  end

  def call_adapter(subscription_information, changeset, action) do
    (subscription_information.adapter |> String.to_atom).send(subscription_information, changeset, action)
  end

  @doc """
  """
  defmacro subscribe(kw) do
    quote do
      use Ecto.Model.Callbacks
      import Ecto.Subscribe.Api

      after_insert :subscribe_after_insert, [__MODULE__, unquote(kw)]
      after_delete :subscribe_after_delete, [__MODULE__, unquote(kw)]
      after_update :subscribe_after_update, [__MODULE__, unquote(kw)]

      def subscribe_after_insert(changeset, model, kw) do
        execute(kw, changeset, model, :create)
        changeset
      end

      def subscribe_after_delete(changeset, model, kw) do
        execute(kw, changeset, model, :delete)
        changeset
      end

      def subscribe_after_update(changeset, model, kw) do
        execute(kw, changeset, model, :update)
        changeset
      end

      def __action__subscribe(), do: true
    end
  end

  def execute(kw, changeset, model, action) do
    {_, repo} = List.keyfind(kw, :repo, 0)
    query_result = query_model_from_system_tbl(repo, Macro.to_string(model))
    case find_subscription(query_result, changeset, model, action) do
      {:false, _} ->
        :do_nothing
      {:true, subscription_information} ->
        call_adapter(subscription_information, changeset, action)
    end
  end

  #
  # Utils
  #
  def query_model_from_system_tbl(repo, model) do
    #model = Macro.to_string(model)
    repo.all(from q in Ecto.Subscribe.Schema.SystemTable, where: q.model == ^model)
  end

  def get_opts_field(opts, field) do
    case List.keyfind(opts, field, 0) do
      nil ->
        ""
      {_, val} when is_list(val) ->
        val
      {_, val} ->
        val |> to_string
    end
  end

  def get_actions("") do
    [:create, :update, :delete]
  end

  def get_actions(actions) do
    actions
  end

  def find_subscription([], _, _, _) do
    {:false, []}
  end

  def find_subscription([subscription_row_in_db | subscription_in_db], changeset, model, action) do
    find_subscription(subscription_row_in_db, subscription_in_db, changeset, model, action)
  end

  def find_subscription(subscription_row_in_db, subscription_in_db, changeset, model, action) do
    find_subscription_helper(subscription_row_in_db, subscription_in_db, changeset, model, action)
  end

  def find_subscription_helper(subscription_row_in_db, subscription_in_db, changeset, model, action) do
    actions = string_to_actions(subscription_row_in_db.subscription_actions)
    case Enum.member?(actions, action) do
      true ->
        {field_name, operator, val} = db_row_to_map(subscription_row_in_db.subscription_info, model)
        validate_change(subscription_row_in_db, changeset.changes, field_name, operator, val)
      false ->
        is_subscription_for_all(actions, subscription_in_db, changeset, model, action)
    end
  end

  def validate_change(subscription_row_in_db, changes, field_name, operator, val) do
    case Map.get(changes, field_name, 0) do
      nil ->
        :false
      updated_val ->
        case operator do
          "==" ->
            {val == updated_val, subscription_row_in_db}
          ">" ->
            {updated_val > val, subscription_row_in_db}
          "<" ->
            {updated_val > val, subscription_row_in_db}
          _ ->
            {:false, []}
        end
    end
  end

  def is_subscription_for_all([:all], subscription_in_db, _, _, _) do
    {:true, subscription_in_db}
  end

  def is_subscription_for_all(_, subscription_in_db, changeset, model, action) do
    find_subscription(subscription_in_db, changeset, model, action)
  end

  def db_row_to_map(str, model) do
    [name, operator, val] = String.split(str, " ")
    type = model.__schema__(:field, name |> String.to_atom)
    {String.to_atom(name), operator, get_val_with_correct_type_from_string(type, val)}
  end

  def actions_to_string(actions) do
    Enum.reduce(actions, "", fn(act, acc) -> acc <> (act |> Atom.to_string) <> "," end) |> String.strip ?,
  end

  def string_to_actions(str) do
    splitten_string = String.split(str, ",")
    for s <- splitten_string do
      s |> String.to_atom
    end
  end

  # TODO think about more flexible way how to convert to correct types
  def get_val_with_correct_type_from_string(type, val) do
    case type do
      :integer -> String.to_integer val
      :float   -> String.to_float val
      :boolean -> String.to_atom val
      _ -> val
    end
  end
end
