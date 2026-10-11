// Cloudflare AI from the steps' answers (`accounts`, `usage`, `plan`, `bills`):
// today's Workers AI neurons against the 10k a day, the month's neurons past
// 10k on each UTC day priced on Workers Paid (never the month's total), the
// month's tokens, AI Gateway's tokens and its estimate of what the upstream
// providers charge (not on the Cloudflare bill), and the last invoice.
// Numbers are read from the text so money never passes through a binary float.

// Workers AI pricing, checked 2026-10-11:
// https://developers.cloudflare.com/workers-ai/platform/pricing/
var DAILY_NEURONS = 10000;
var PRICE_PER_NEURON = '0.000011';   // $0.011 per 1k neurons past the day's 10k, on Workers Paid
var TOKEN_HINT = 'Use a Cloudflare API token with Account Analytics: Read.';
var BILLING_HINT = 'Give the token Billing: Read to see the plan, the overage and invoices';
var MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

function read(response, context) {
    var answers;
    try { answers = jsonDecimal(response.text || ''); } catch (e) { answers = null; }
    if (!answers || typeof answers !== 'object' || !answers.usage || typeof answers.usage !== 'object') {
        return { error: { parseFailed: "Failed to parse Cloudflare's answer" } };
    }

    var usage = answers.usage;
    if (Array.isArray(usage.errors) && usage.errors.length) {
        var problem = usage.errors[0] || {}, message = String(problem.message || 'unknown error');
        var code = problem.extensions && problem.extensions.code;
        if (code === 'authz' || /not authori[sz]ed|authentication/i.test(message)) return { error: { sessionExpired: TOKEN_HINT } };
        return { error: { parseFailed: 'Cloudflare: ' + message } };
    }
    var account = usage.data && usage.data.viewer && Array.isArray(usage.data.viewer.accounts) ? usage.data.viewer.accounts[0] : null;
    if (!account) return { error: { sessionExpired: TOKEN_HINT } };

    var result = { quotas: [], notes: [] };

    // Today's neurons, against the 10k a day; resets at 00:00 UTC.
    var today = rows(account.today).reduce(function (n, row) { return n + count(row.sum && row.sum.totalNeurons); }, 0);
    var midnight = Math.floor(context.now / 86400) * 86400 + 86400;
    result.quotas.push({
        type: 'model', name: 'Workers AI neurons', group: 'Workers AI',
        percentRemaining: Math.max(0, DAILY_NEURONS - today) * 100 / DAILY_NEURONS,
        resetsAt: midnight, windowSeconds: 86400,
        resetText: short(today) + ' / ' + short(DAILY_NEURONS) + ' neurons today'
    });

    // The month by day and model: each day's neurons past 10k, and the tokens.
    var byDay = {}, byModel = {}, tokensIn = 0, tokensOut = 0;
    rows(account.days).forEach(function (row) {
        var day = row.dimensions && row.dimensions.date, model = modelName(row.dimensions && row.dimensions.modelId);
        var neurons = count(row.sum && row.sum.totalNeurons);
        if (day) byDay[day] = (byDay[day] || 0) + neurons;
        byModel[model] = (byModel[model] || 0) + neurons;
        tokensIn += count(row.sum && row.sum.totalInputTokens);
        tokensOut += count(row.sum && row.sum.totalOutputTokens);
    });
    var over = Object.keys(byDay).reduce(function (n, day) { return n + Math.max(0, byDay[day] - DAILY_NEURONS); }, 0);
    if (tokensIn + tokensOut > 0) {
        result.notes.push({ group: 'Workers AI', label: 'Workers AI tokens',
                            text: short(tokensIn) + ' in · ' + short(tokensOut) + ' out this month' + top(byModel) });
    }

    // AI Gateway: what the upstream providers charge, by Gateway's estimate.
    var gatewayTokens = 0, gatewayCost = '0', gatewayModels = {};
    rows(account.gateway).forEach(function (row) {
        var tokens = count(row.sum && row.sum.tokensIn) + count(row.sum && row.sum.tokensOut);
        gatewayTokens += tokens;
        if (isDecimal(row.sum && row.sum.cost)) gatewayCost = decimalAdd(gatewayCost, String(row.sum.cost));
        var model = modelName(row.dimensions && row.dimensions.model);
        gatewayModels[model] = (gatewayModels[model] || 0) + tokens;
    });
    if (gatewayTokens > 0 || Number(gatewayCost) > 0) {
        result.notes.push({ group: 'AI Gateway', label: 'AI Gateway',
                            text: short(gatewayTokens) + ' tokens · $' + decimalCents(gatewayCost) +
                                  ' at providers (est.) this month' + top(gatewayModels) });
    }

    // The plan: Workers Paid charges past the day's 10k; Free stops there instead.
    var subscriptions = succeeded(answers.plan);
    if (subscriptions) {
        var paid = subscriptions.some(function (s) { return s && s.rate_plan && s.rate_plan.id === 'workers_paid'; });
        result.plan = paid ? 'Workers Paid' : 'Free';
        if (paid) {
            var amount = decimalMultiply(String(over), PRICE_PER_NEURON);
            result.cost = { kind: 'apiCost', used: amount, resetText: 'This month · est.',
                            lines: [{ label: 'Workers AI neurons', used: amount, detail: short(over) + ' past 10k a day' }] };
        }
    } else {
        result.notes.push({ group: 'Bill', label: 'Bill', text: BILLING_HINT });
    }

    var invoices = succeeded(answers.bills);
    var last = invoices && invoices[0];
    if (last && isDecimal(last.amount_to_pay)) {
        result.notes.push({ group: 'Bill', label: 'Last invoice',
                            text: '$' + decimalCents(String(last.amount_to_pay)) + dated(last.occurred_at) });
    }
    return result;
}

function rows(value) { return Array.isArray(value) ? value : []; }

function count(value) { var n = Number(value); return isFinite(n) && n > 0 ? n : 0; }

function isDecimal(value) { return value != null && /^-?\d+(\.\d+)?([eE][+-]?\d+)?$/.test(String(value)); }

/// A REST answer's `result` list when Cloudflare said yes; a refusal is null.
function succeeded(answer) {
    return answer && typeof answer === 'object' && answer.success === true && Array.isArray(answer.result) ? answer.result : null;
}

/// "@cf/meta/llama-3.1-8b-instruct" → "llama-3.1-8b-instruct".
function modelName(id) {
    var text = typeof id === 'string' && id ? id : 'unknown';
    return text.split('/').pop();
}

/// " · a, b, c": the three busiest, most first.
function top(byName) {
    var names = Object.keys(byName).filter(function (n) { return byName[n] > 0; })
        .sort(function (a, b) { return byName[b] - byName[a]; }).slice(0, 3);
    return names.length ? ' · ' + names.join(', ') : '';
}

/// 4200 → "4.2k", 10000 → "10k", 1021918 → "1M".
function short(n) {
    function one(x) { var t = (Math.round(x * 10) / 10).toFixed(1); return t.replace(/\.0$/, ''); }
    if (n >= 1e9) return one(n / 1e9) + 'B';
    if (n >= 1e6) return one(n / 1e6) + 'M';
    if (n >= 1e3) return one(n / 1e3) + 'k';
    return String(Math.round(n));
}

/// " · Sep 21", from an ISO 8601 time; nothing when it can't be read.
function dated(text) {
    var match = typeof text === 'string' && text.match(/^\d{4}-(\d{2})-(\d{2})/);
    return match ? ' · ' + MONTHS[Number(match[1]) - 1] + ' ' + Number(match[2]) : '';
}
