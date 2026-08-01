defmodule SymphonyElixir.Codex.InterruptionClassifierTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.InterruptionClassifier

  describe "classify/2" do
    test "classifies explicit turn interruption methods with string or atom names" do
      assert %{kind: :terminal_method, method: "turn/aborted"} =
               InterruptionClassifier.classify("turn/aborted", %{})

      assert %{kind: :terminal_method, method: "turn/interrupted"} =
               InterruptionClassifier.classify(:"turn/interrupted", %{})
    end

    test "classifies abnormal explicit turn statuses with string keys" do
      status = %{"type" => "cancelled", "reason" => "user_interrupted"}
      payload = %{"params" => %{"turn" => %{"id" => "turn-1", "status" => status}}}

      assert %{
               kind: :turn_status,
               status: ^status,
               status_type: "cancelled"
             } = InterruptionClassifier.classify("turn/completed", payload)

      for status_type <- ["aborted", "cancelled", "canceled", "failed", "interrupted"] do
        payload = %{"params" => %{"turn" => %{"status" => status_type}}}

        assert %{kind: :turn_status, status: ^status_type, status_type: ^status_type} =
                 InterruptionClassifier.classify("turn/completed", payload)
      end
    end

    test "classifies abnormal explicit turn statuses with atom and mixed keys" do
      atom_status = %{type: "INTERRUPTED", reason: "operator"}
      atom_payload = %{params: %{turn: %{id: "turn-2", status: atom_status}}}

      assert %{kind: :turn_status, status: ^atom_status, status_type: "interrupted"} =
               InterruptionClassifier.classify("turn/completed", atom_payload)

      mixed_payload = %{"params" => %{turn: %{"status" => "failed"}}}

      assert %{kind: :turn_status, status: "failed", status_type: "failed"} =
               InterruptionClassifier.classify("turn/completed", mixed_payload)
    end

    test "does not treat generic status fields as turn control" do
      benign_payloads = [
        %{"params" => %{"status" => "cancelled"}},
        %{params: %{status: %{type: "interrupted"}}},
        %{"status" => "aborted"},
        %{status: %{type: "failed"}},
        %{
          "params" => %{
            "server" => "sentry",
            "status" => "cancelled",
            "failureReason" => "turn/interrupted while starting MCP server"
          }
        }
      ]

      for payload <- benign_payloads do
        assert InterruptionClassifier.classify("mcpServer/startupStatus/updated", payload) == nil
      end
    end

    test "does not interpret arbitrary notification text as a turn interruption" do
      benign_payloads = [
        %{"params" => %{"delta" => "Document the turn/interrupted event"}},
        %{params: %{message: "The command was aborted by user in the example"}},
        %{
          "params" => %{
            "item" => %{
              "type" => "agentMessage",
              "text" => "Possible markers include <turn_aborted> and turn_aborted"
            }
          }
        }
      ]

      for payload <- benign_payloads do
        assert InterruptionClassifier.classify("item/agentMessage/delta", payload) == nil
      end
    end

    test "keeps the legacy marker fallback limited to completed function-call output" do
      string_payload = %{
        "params" => %{
          "item" => %{
            "type" => "function_call_output",
            "output" => "aborted by user after 10.0s"
          }
        }
      }

      atom_payload = %{
        params: %{
          item: %{
            type: "function_call_output",
            output: "runner emitted <turn_aborted>"
          }
        }
      }

      assert %{kind: :legacy_function_output, marker: "aborted by user"} =
               InterruptionClassifier.classify("item/completed", string_payload)

      assert %{kind: :legacy_function_output, marker: "<turn_aborted>"} =
               InterruptionClassifier.classify(:"item/completed", atom_payload)

      command_payload = %{
        "params" => %{
          "item" => %{
            "type" => "commandExecution",
            "aggregatedOutput" => "aborted by user after testing the literal text"
          }
        }
      }

      assert InterruptionClassifier.classify("item/completed", command_payload) == nil
      assert InterruptionClassifier.classify("item/started", string_payload) == nil
    end

    test "ignores successful and missing explicit turn statuses" do
      assert InterruptionClassifier.classify(
               "turn/completed",
               %{"params" => %{"turn" => %{"status" => %{"type" => "completed"}}}}
             ) == nil

      assert InterruptionClassifier.classify("turn/completed", %{}) == nil
    end
  end
end
