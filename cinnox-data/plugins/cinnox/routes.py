"""
Cinnox plugin — FastAPI HTTP route handlers.

Wraps the tool functions as REST endpoints mounted under /api/cinnox/.

Note: plugin modules are loaded by plugin_loader via importlib (not
as real packages), so use sys.modules to reference sibling modules.
"""

import sys


def _get_tools():
    """Lazy-import the tools module registered by plugin_loader."""
    return sys.modules["autoservice.plugins.cinnox.tools"]


async def get_customer(identifier: str) -> dict:
    """GET /api/cinnox/customers/{identifier} — look up a customer."""
    tools = _get_tools()
    return tools.customer_lookup(identifier)


async def get_billing(account_id: str, start_date: str = None, end_date: str = None) -> dict:
    """GET /api/cinnox/customers/{account_id}/billing — billing history."""
    tools = _get_tools()
    return tools.billing_query(account_id, start_date, end_date)


async def get_subscriptions(account_id: str) -> dict:
    """GET /api/cinnox/customers/{account_id}/subscriptions — active subscriptions."""
    tools = _get_tools()
    return tools.subscription_query(account_id)
