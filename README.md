# PostgreSQL OpenAI Integration

This project integrates OpenAI's GPT models with PostgreSQL, allowing for AI-powered responses directly within a PostgreSQL database.

## Features

- Custom PostgreSQL database with Python (plpython3u) extension
- Integration with OpenAI API for generating AI responses
- Docker-based setup for easy deployment and scaling
- Environment variable management for secure API key handling

## Prerequisites

- Docker
- Docker Compose
- OpenAI API Key

## Installation

You can install this project in two ways:

### Option 1: Using the pre-built Docker image

1. Pull the image from the command line:
   ```bash
   docker pull ghcr.io/data2json/postresql-openai:v0.0.1
   ```

2. Use as base image in your Dockerfile:
   ```dockerfile
   FROM ghcr.io/data2json/postresql-openai:v0.0.1
   ```

### Option 2: Building from source

1. Clone the repository:
   ```
   git clone https://github.com/your-username/postgres-openai.git
   cd postgres-openai
   ```

2. Create a `.env` file in the project root with the following content:
   ```
   POSTGRES_PASSWORD=your_postgres_password
   OPENAI_API_KEY=your_openai_api_key
   OPENAI_API_BASE=http://your-api-base-url:port/v1
   ```

   Replace the values with your actual PostgreSQL password, OpenAI API key, and API base URL.

3. Build and start the Docker containers:
   ```
   docker-compose up -d --build
   ```

## Usage

Once the container is up and running, you can connect to the PostgreSQL database and use the AI-powered functions.

1. Connect to the database:
   ```
   docker-compose exec db pgcli
   ```

2. Insert a question into the `ai_responses` table:
   ```sql
   INSERT INTO ai_responses (input_text) VALUES ('Why is the sky blue?');
   ```

3. Retrieve the AI-generated response:
   ```sql
   SELECT * FROM ai_responses ORDER BY id DESC LIMIT 1;
   ```

## Project Structure

- `Dockerfile`: Defines the PostgreSQL image with Python and OpenAI integration
- `docker-compose.yml`: Orchestrates the Docker setup
- `init.sql`: Initializes the database schema and functions

## Customization

You can customize the conversation templates by modifying the `upsert_conversation_template` function calls in the `init.sql` file.

## Troubleshooting

If you encounter any issues:

1. Check that your `.env` file is correctly set up with valid credentials.
2. Ensure Docker and Docker Compose are up to date.
3. Check the Docker logs for any error messages:
   ```
   docker-compose logs db
   ```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the BSD License - see the [LICENSE](LICENSE) file for details.
