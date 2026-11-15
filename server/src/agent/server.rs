// The MCP server, on the official Rust SDK (rmcp). rmcp speaks the protocol: the initialize
// handshake of the older versions, the per-request flow of 2026-07-28, server/discover,
// stdio framing and Streamable HTTP. This file only answers its questions with the tools of
// tools.rs, for the caller of each request.
use super::{client::Client, tools};
use rmcp::{
    ErrorData, RoleServer, ServerHandler,
    model::{
        CallToolRequestMethod, CallToolRequestParams, CallToolResponse, CallToolResult,
        Implementation, InitializeRequestParams, InitializeResult, ListToolsRequestMethod,
        ListToolsResult, PaginatedRequestParams, ResultType, ServerCapabilities, Tool,
    },
    service::RequestContext,
};
use std::sync::Arc;

// Who a request is served for: the client with their token, the scopes of that token (None when
// the API could not tell), and whether a path in a call means a file next to this server.
pub struct Caller {
    pub client: Client,
    pub scopes: Option<Vec<String>>,
    pub files: bool,
}

impl Caller {
    fn offered(&self) -> Vec<&'static serde_json::Value> {
        tools::offered(self.scopes.as_deref(), self.files)
    }
}

// The stdio server has one caller for its whole life. The hosted endpoint makes a handler per
// request and puts the caller of that request into the request's extensions.
#[derive(Clone, Default)]
pub struct Pendenz {
    caller: Option<Arc<Caller>>,
}

impl Pendenz {
    pub fn for_caller(caller: Caller) -> Self {
        Self {
            caller: Some(Arc::new(caller)),
        }
    }

    fn caller(&self, context: &RequestContext<RoleServer>) -> Result<Arc<Caller>, ErrorData> {
        if let Some(caller) = &self.caller {
            return Ok(caller.clone());
        }
        context
            .extensions
            .get::<axum::http::request::Parts>()
            .and_then(|parts| parts.extensions.get::<Arc<Caller>>())
            .cloned()
            .ok_or_else(|| ErrorData::internal_error("The request has no caller.", None))
    }
}

fn info(tools: bool) -> InitializeResult {
    let capabilities = if tools {
        ServerCapabilities::builder().enable_tools().build()
    } else {
        ServerCapabilities::default()
    };
    let mut info = InitializeResult::new(capabilities);
    info.server_info = Implementation::new("pendenz", env!("CARGO_PKG_VERSION"));
    info.instructions = Some(tools::INSTRUCTIONS.trim_end().to_owned());
    info
}

impl ServerHandler for Pendenz {
    fn get_info(&self) -> InitializeResult {
        // What server/discover shows, without a caller: the tools are there for a token that
        // may use them.
        info(true)
    }

    async fn initialize(
        &self,
        request: InitializeRequestParams,
        context: RequestContext<RoleServer>,
    ) -> Result<InitializeResult, ErrorData> {
        let caller = self.caller(&context)?;
        context.peer.set_peer_info(request.clone());
        let mut result = self.negotiate_initialize(&request)?;
        // A token whose scopes allow no tool is told there are none.
        result.capabilities = info(!caller.offered().is_empty()).capabilities;
        Ok(result)
    }

    async fn list_tools(
        &self,
        _request: Option<PaginatedRequestParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, ErrorData> {
        let caller = self.caller(&context)?;
        let offered = caller.offered();
        if offered.is_empty() {
            return Err(ErrorData::method_not_found::<ListToolsRequestMethod>());
        }
        let tools = offered
            .into_iter()
            .map(|tool| serde_json::from_value::<Tool>(tool.clone()))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|error| ErrorData::internal_error(error.to_string(), None))?;
        Ok(ListToolsResult::with_all_items(tools))
    }

    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, ErrorData> {
        let caller = self.caller(&context)?;
        if caller.offered().is_empty() {
            return Err(ErrorData::method_not_found::<CallToolRequestMethod>());
        }
        let arguments = request.arguments.map(serde_json::Value::Object);
        let result = tools::call(
            &caller.client,
            caller.scopes.as_deref(),
            caller.files,
            &request.name,
            arguments,
        )
        .await;
        let mut result: CallToolResult = serde_json::from_value(result)
            .map_err(|error| ErrorData::internal_error(error.to_string(), None))?;
        // Required from 2026-07-28 on. rmcp drops it again for a client of an older version.
        result.result_type = Some(ResultType::COMPLETE);
        Ok(result.into())
    }

    // The arguments are checked by tools.rs against tools.json, with the defaults, trimming
    // and messages the tools always had, so rmcp is not given the tool to check them itself.
    fn get_tool(&self, _name: &str) -> Option<Tool> {
        None
    }
}
