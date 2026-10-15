# Sedge database

Taken from the migrations in `Packages/SedgeCore/Sources/SedgeCore/SedgeDatabase.swift`:
`v1` (accounts, transactions, meta) and `v2` (the merchant graph: entities, edges and
`transactions.merchant_id`).

```mermaid
erDiagram
    accounts ||--o{ transactions : "account_id"
    transactions |o--o| transactions : "pending_transaction_id (posted to pending copy)"
    entities |o--o{ transactions : "merchant_id"
    transactions ||--o{ edges : "source (at_merchant, from_account, refund_of, recurring)"
    entities ||--o{ edges : "source (in_category: merchant)"
    entities ||--o{ edges : "target (merchant, account, category)"
    transactions |o--o{ edges : "target (refund_of: original purchase)"

    accounts {
        text account_id PK
        text name "not null"
        text official_name
        text mask
        text type "not null"
        text subtype
        text balances "not null, JSON: current, available, limit, currency codes"
    }

    transactions {
        text transaction_id PK
        text account_id FK "not null, indexed, references accounts"
        text date "not null, indexed, YYYY-MM-DD"
        text name "not null, raw statement name"
        double amount "not null, positive means money out"
        text iso_currency_code
        boolean pending "not null"
        text pending_transaction_id "on a posted row: the pending copy it replaces"
        text merchant_name "comparison baseline only, the organizer never reads it"
        text personal_finance_category "JSON; comparison baseline only, the organizer never reads it"
        text merchant_id "indexed, v2, an entities.id of kind merchant"
    }

    meta {
        text key PK "today only as_of"
        text value "not null"
    }

    entities {
        text id PK "e.g. merchant:value mart, account:maya-card, category:groceries"
        text kind "not null: merchant, account or category"
        text name "not null, display name"
    }

    edges {
        text source "not null, indexed"
        text kind "not null"
        text target "not null, indexed"
        text cadence "recurring only: weekly, biweekly, monthly"
        double typical_amount "recurring only"
        text next_expected_date "recurring only, YYYY-MM-DD"
    }
```

- **accounts** and **transactions** keep Plaid's field names. A transaction belongs to one
  account (the only foreign key SQLite enforces).
- **Pending to posted:** when a charge posts, Plaid sends a new row whose
  `pending_transaction_id` names the pending copy. `save` deletes that pending copy, so the
  link usually points at a row that is gone. It only records which pending copy was replaced.
- **merchant_name** and **personal_finance_category** are Plaid's own cleanup. They are kept
  as the comparison baseline only, and the organizer never reads them. The fake personas leave them empty.
- **meta** holds facts about the dataset. Today that is only `as_of`, the dataset's "today".
- **entities** and **edges** are the merchant graph, rebuilt by `Organizer.organize`.
  `edges.source` and `edges.target` hold either a `transaction_id` or an `entities.id`,
  depending on `kind`, so SQLite doesn't enforce them as foreign keys:

  | kind | source | target |
  |---|---|---|
  | at_merchant | transaction | merchant entity |
  | from_account | transaction | account entity |
  | in_category | merchant entity | category entity |
  | refund_of | refund transaction | the purchase it reverses |
  | recurring | transaction | merchant entity, plus cadence, typical amount, next date |

- **transactions.merchant_id** copies the at_merchant edge so "spending at X" is one indexed
  lookup. With `useGraph` off, every raw name is its own merchant and there are no
  refund_of or recurring edges.

## Database files

Each dataset has its own SQLite file, and every file has the tables above:

- `sedge-<persona>.sqlite` for each fake persona (`sedge-maya.sqlite`, `sedge-daniel.sqlite`,
  `sedge-jordan.sqlite`, `sedge-elena.sqlite`), loaded from `tools/data/<persona>/`.
- One separate bank file for Plaid data (`sedge.sqlite`).

The rule: Plaid data always goes into the bank file and never into a persona's file, and
the app reads the chosen database at launch. Building this is #13's job. Today the app
chooses the file at launch (`-persona <name>` opens that persona's file, otherwise
`sedge.sqlite`), but the Plaid save in `ConnectBankView.swift` still writes to whichever
file is open.
