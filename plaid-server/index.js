'use strict';

// The Plaid server Sedge talks to on localhost:8000. It is Plaid's quickstart Node server
// (https://github.com/plaid/quickstart, MIT license in LICENSE), cut down to the three routes
// Sedge calls. /api/all_transactions is Sedge's own addition.

// read env vars from .env file
require('dotenv').config();
const { Configuration, PlaidApi, Products, PlaidEnvironments } = require('plaid');
const util = require('util');
const express = require('express');
const cors = require('cors');

const APP_PORT = process.env.APP_PORT || 8000;
const PLAID_CLIENT_ID = process.env.PLAID_CLIENT_ID;
const PLAID_SECRET = process.env.PLAID_SECRET;
const PLAID_ENV = process.env.PLAID_ENV || 'sandbox';

const sleep = (ms) => new Promise(resolve => setTimeout(resolve, ms));

// PLAID_PRODUCTS is a comma-separated list of products to use when initializing
// Link.
const PLAID_PRODUCTS = (process.env.PLAID_PRODUCTS || Products.Transactions).split(
  ',',
);

// PLAID_COUNTRY_CODES is a comma-separated list of countries for which users
// will be able to select institutions from.
const PLAID_COUNTRY_CODES = (process.env.PLAID_COUNTRY_CODES || 'US').split(
  ',',
);

// Parameters used for the OAuth redirect Link flow.
//
// The OAuth redirect flow requires an endpoint on the developer's website
// that the bank website should redirect to. You will need to configure
// this redirect URI for your client ID through the Plaid developer dashboard
// at https://dashboard.plaid.com/team/api.
const PLAID_REDIRECT_URI = process.env.PLAID_REDIRECT_URI || '';

// We store the access_token in memory - in production, store it in a secure
// persistent data store
let ACCESS_TOKEN = null;
let PUBLIC_TOKEN = null;
let ITEM_ID = null;

// Initialize the Plaid client
// Find your API keys in the Dashboard (https://dashboard.plaid.com/account/keys)

const configuration = new Configuration({
  basePath: PlaidEnvironments[PLAID_ENV],
  baseOptions: {
    headers: {
      'PLAID-CLIENT-ID': PLAID_CLIENT_ID,
      'PLAID-SECRET': PLAID_SECRET,
      'Plaid-Version': '2020-09-14',
    },
  },
});

const client = new PlaidApi(configuration);

const app = express();
app.use(
  express.urlencoded({
    extended: false,
  }),
);
app.use(express.json());
app.use(cors());

// Create a link token with configs which we can then use to initialize Plaid Link client-side.
// See https://plaid.com/docs/#create-link-token
app.post('/api/create_link_token', function (request, response, next) {
  Promise.resolve()
    .then(async function () {
      const configs = {
        user: {
          // This should correspond to a unique id for the current user.
          client_user_id: 'user-id',
        },
        client_name: 'Plaid Quickstart',
        products: PLAID_PRODUCTS,
        country_codes: PLAID_COUNTRY_CODES,
        language: 'en',
      };

      if (PLAID_REDIRECT_URI !== '') {
        configs.redirect_uri = PLAID_REDIRECT_URI;
      }
      const createTokenResponse = await client.linkTokenCreate(configs);
      prettyPrintResponse(createTokenResponse);
      response.json(createTokenResponse.data);
    })
    .catch(next);
});

// Exchange token flow - exchange a Link public_token for
// an API access_token
// https://plaid.com/docs/#exchange-token-flow
app.post('/api/set_access_token', function (request, response, next) {
  PUBLIC_TOKEN = request.body.public_token;
  Promise.resolve()
    .then(async function () {
      const tokenResponse = await client.itemPublicTokenExchange({
        public_token: PUBLIC_TOKEN,
      });
      prettyPrintResponse(tokenResponse);
      ACCESS_TOKEN = tokenResponse.data.access_token;
      ITEM_ID = tokenResponse.data.item_id;
      response.json({
        // the 'access_token' is a private token, DO NOT pass this token to the frontend in your production environment
        access_token: ACCESS_TOKEN,
        item_id: ITEM_ID,
        error: null,
      });
    })
    .catch(next);
});

// Sedge: return every added transaction with its accounts for local storage.
app.get('/api/all_transactions', function (request, response, next) {
  Promise.resolve()
    .then(async function () {
      let cursor = null;
      let added = [];
      let hasMore = true;
      while (hasMore) {
        // Ask for the bank's raw text too: Sandbox rewrites `name` for merchants it recognizes.
        const { data } = await client.transactionsSync({
          access_token: ACCESS_TOKEN, cursor, options: { include_original_description: true },
        });
        cursor = data.next_cursor;
        // An empty cursor means Plaid has not prepared the history yet.
        if (cursor === '') {
          await sleep(2000);
          continue;
        }
        added = added.concat(data.added);
        hasMore = data.has_more;
      }
      const accountsResponse = await client.accountsGet({ access_token: ACCESS_TOKEN });
      response.json({ accounts: accountsResponse.data.accounts, transactions: added });
    })
    .catch(next);
});

app.listen(APP_PORT, function () {
  console.log('plaid-quickstart server listening on port ' + APP_PORT);
});

const prettyPrintResponse = (response) => {
  console.log(util.inspect(response.data, { colors: true, depth: 4 }));
};

const formatError = (error) => {
  return {
    error: { ...error?.data, status_code: error?.status },
  };
};

app.use('/api', function (error, request, response, next) {
  if (error.response?.data) {
    prettyPrintResponse(error.response);
  } else {
    console.log(error.message || error);
  }
  const statusCode = error.response?.status || 500;
  response.status(statusCode).json(formatError(error.response));
});
