defmodule ExAtlas.Spec.TemplateTest do
  use ExUnit.Case, async: true

  alias ExAtlas.Spec.Template

  test "inspect leaves out env and raw, which hold secrets" do
    template = %Template{
      id: "t1",
      provider: :runpod,
      name: "trainer",
      env: %{"WANDB_API_KEY" => "s3cr3t-value"},
      raw: %{"env" => %{"WANDB_API_KEY" => "s3cr3t-value"}}
    }

    text = inspect(template)
    assert text =~ "trainer"
    refute text =~ "s3cr3t-value"
    refute text =~ "WANDB_API_KEY"
  end
end
