package core

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestSyncHttp(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Marker", "yes")
		w.WriteHeader(200)
		w.Write([]byte(`{"ok":true}`))
	}))
	defer server.Close()

	args := []json.RawMessage{
		json.RawMessage(`{"url":"` + server.URL + `/data","method":"GET","headers":{"X-A":"1"}}`),
	}
	out, err := syncHttp(nil, args)
	if err != nil {
		t.Fatalf("syncHttp: %v", err)
	}
	m, _ := out.(map[string]any)
	if m["status"].(int) != 200 {
		t.Fatalf("status: %v", m["status"])
	}
	if m["bodyB64"] == "" {
		t.Fatal("bodyB64 empty")
	}
}

func TestSyncHttpPost(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" {
			t.Errorf("method: %s", r.Method)
		}
		w.WriteHeader(200)
		w.Write([]byte(`ok`))
	}))
	defer server.Close()

	args := []json.RawMessage{
		json.RawMessage(`{"url":"` + server.URL + `/submit","method":"POST","body":"u=1&p=2"}`),
	}
	if _, err := syncHttp(nil, args); err != nil {
		t.Fatalf("syncHttp POST: %v", err)
	}
}

func TestSyncHttpEmptyURL(t *testing.T) {
	if _, err := syncHttp(nil, []json.RawMessage{json.RawMessage(`{"url":""}`)}); err == nil {
		t.Fatal("empty url 应报错")
	}
}
