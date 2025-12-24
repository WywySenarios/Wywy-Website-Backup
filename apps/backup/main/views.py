from typing import List
from django.views.decorators.csrf import ensure_csrf_cookie
from django.http import HttpResponse, HttpRequest, JsonResponse, HttpResponseBadRequest, HttpResponseNotModified
import os

@ensure_csrf_cookie
def index(request: HttpRequest) -> HttpResponse:
    """This server tries to archive WAL files POST'ed to this endpoint, without security (it's assumed this is run on a home server). @TODO fix security

    Args:
        request (HttpRequest): The incoming client request.

    Returns:
        HttpResponse: Return 200 if the server successfully archived the file and something else if not.
    """
    # first verify that it's a post request
    if not request.method == "POST":
        return JsonResponse({"detail": "csrf cookie set"})
    
    # check that the body is not empty
    if len(request.body) == 0:
        return HttpResponseBadRequest()
    
    # check that the URL does not give an empty file name
    path_chunks: List[str] = request.path.split("/", 1)
    if len(path_chunks) < 2:
        return HttpResponseBadRequest()
    # extract the file destination
    destination_name: str = path_chunks[1]
    
    # attempt to store the request's data
    # check if the filename already exists
    os.makedirs("data", exist_ok=True)
    if os.path.exists(f"data/{destination_name}"):
        # the only way this succeeds is if the file's contents are exactly the same as the request's contents
        with open(f"data/{destination_name}", "rb") as f:
            if f.read() == request.body:
                return HttpResponse()
            else:
                # @TODO find a better response
                return HttpResponseBadRequest()
    
    # write in the new data
    with open(f"data/{destination_name}", "wb") as f:
        f.write(request.body)
    
    return HttpResponse()