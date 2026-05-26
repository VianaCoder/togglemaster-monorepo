# ToggleMaster

## Arquitetura

```text
Cliente/Admin
   |
   +--> auth-service (API keys)
   +--> flag-service (CRUD de flags)
   +--> targeting-service (regras)
   |
   +--> evaluation-service (decisao)
	   |
	   +--> Redis (cache)
	   +--> flag-service
	   +--> targeting-service
	   +--> SQS (evento)
		    |
		    +--> analytics-service
			     |
			     +--> DynamoDB
```

## Endpoints

### auth-service
- GET /health
- POST /admin/keys
- GET /validate

### flag-service
- GET /health
- GET /flags
- POST /flags
- GET /flags/{name}
- PUT /flags/{name}

### targeting-service
- GET /health
- POST /rules
- GET /rules/{flag_name}
- PUT /rules/{flag_name}

### evaluation-service
- GET /health
- GET /evaluate?user_id=<id>&flag_name=<name>

### analytics-service
- GET /health

