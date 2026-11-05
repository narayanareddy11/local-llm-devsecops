import httpx
import pytest
from fastapi.testclient import TestClient

from services.app import create_app


def test_catalog_contract():
    with TestClient(create_app("catalog")) as client:
        assert client.get("/healthz").status_code == 200
        assert len(client.get("/items").json()) == 3
        assert client.get("/items/item-1").json()["name"] == "Trail backpack"
        assert client.get("/items/missing").status_code == 404


def test_assistant_uses_context_and_internal_llm():
    seen = []

    def handler(request):
        seen.append(request)
        if request.url.host == "catalog":
            return httpx.Response(200, json={"id": "item-1", "name": "Backpack"})
        return httpx.Response(200, json={"choices": [{"message": {"content": "A backpack."}}]})

    with TestClient(create_app("assistant", httpx.MockTransport(handler))) as client:
        result = client.post("/answer", json={"question": "Summarize", "item_id": "item-1"})
    assert result.json() == {"answer": "A backpack."}
    assert [r.url.host for r in seen] == ["catalog", "llm"]
    assert b"Backpack" in seen[1].content
    assert seen[0].headers["x-request-id"] == seen[1].headers["x-request-id"]


@pytest.mark.parametrize(
    "payload",
    [
        {"question": ""},
        {"question": "   "},
        {"question": "x" * 2001},
        {"question": "x", "item_id": "../../secret"},
    ],
)
def test_invalid_input_never_calls_upstream(payload):
    def unexpected(request):
        pytest.fail("Invalid input reached upstream")

    with TestClient(create_app("assistant", httpx.MockTransport(unexpected))) as client:
        assert client.post("/answer", json=payload).status_code == 422


def test_unknown_item_does_not_call_model():
    def handler(request):
        assert request.url.host == "catalog"
        return httpx.Response(404)

    with TestClient(create_app("assistant", httpx.MockTransport(handler))) as client:
        assert (
            client.post("/answer", json={"question": "x", "item_id": "item-9"}).status_code == 404
        )


def test_upstream_timeout_is_504():
    def handler(request):
        raise httpx.ReadTimeout("private backend address", request=request)

    with TestClient(create_app("gateway", httpx.MockTransport(handler))) as client:
        response = client.get("/api/v1/items")
        assert response.status_code == 504
        assert "private" not in response.text


def test_malformed_model_response_is_502():
    with TestClient(
        create_app("assistant", httpx.MockTransport(lambda r: httpx.Response(200, json={})))
    ) as client:
        assert client.post("/answer", json={"question": "hello"}).status_code == 502


def test_gateway_forwards_question():
    def handler(request):
        assert request.url.path == "/answer"
        assert b"hello" in request.content
        return httpx.Response(200, json={"answer": "Hi"})

    with TestClient(create_app("gateway", httpx.MockTransport(handler))) as client:
        response = client.post("/api/v1/ask", json={"question": "hello"})
        assert response.json() == {"answer": "Hi"}
        assert "x-request-id" in response.headers
        assert "app_requests_total" in client.get("/metrics").text


def test_gateway_serves_web_chat():
    with TestClient(create_app("gateway")) as client:
        page = client.get("/")
        assert page.status_code == 200
        assert "Local Catalog Assistant" in page.text
        assert "/api/v1/ask" in page.text
