docker compose exec db psql -c "INSERT INTO ai_responses (input_text) VALUES ('Why is the sky blue?'); select * from ai_responses ;"
