# Single image: Chainlit chat UI driving the ADK agent (pipeline_pulse_agent).
#
#   docker build -t pp-chainlit .
#   docker run --rm -p 8000:8000 --env-file pipeline_pulse_agent/.env pp-chainlit
#   open http://localhost:8000
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY pipeline_pulse_agent/ ./pipeline_pulse_agent/
COPY app.py chainlit.md ./

ENV PYTHONUNBUFFERED=1

EXPOSE 8000

# Cloud Run injects $PORT (8080); defaults to 8000 locally. -h = headless.
CMD ["sh", "-c", "chainlit run app.py --host 0.0.0.0 --port ${PORT:-8000} -h"]
