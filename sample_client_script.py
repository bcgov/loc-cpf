import requests

url = "http://0.0.0.0:3000/api/jobs"  # change to your endpoint
url = "https://cpf-dev.apps.gold.devops.gov.bc.ca/api/jobs"  # change to your endpoint

# Rails-style nested params
data = {
    "api_token": "96b37aff7c3ebd0a029c0530488cecae",
    "endpoint_name": "Geocode",
    "options[name1]": "value1",
    "options[name2]": "value2",
    "options[name3]": "value3",
    "input_data_content_type": "text/tsv",
    "output_data_content_type": "text/tsv"
}

# File upload
files = {
    "input_data_file": open("example.tsv", "rb")  # change to your file path
}

response = requests.post(url, data=data, files=files)

print("Status Code:", response.status_code)
print("Response Body:", response.text)